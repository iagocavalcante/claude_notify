defmodule ClaudeNotify.TelegramPoller do
  @moduledoc """
  GenServer that long-polls Telegram getUpdates for:
  - Inline keyboard callbacks (Yes/No button presses)
  - Text messages (/sessions command, prompt text to inject)
  - Dispatcher job commands (/run, /jobs, /cancel, /projects) and
    reply-to-job routing (see the "Job commands" section below)

  Maintains a "selected session" per chat so users can pick a session
  and then type prompts that get injected into that terminal.

  ## Job commands

  `/run [claude|codex] <project> <prompt>` launches a dispatcher job via
  `ClaudeNotify.JobSupervisor.start_job/2`; `/jobs` lists known jobs;
  `/cancel <id>` cancels one; `/projects` opens the working-directory picker.
  Replying to a job's activity message resumes that job (a NEW job, wired
  with `resume_session_id` - see `ClaudeNotify.JobRunner`'s moduledoc for
  what "resume" does and does not carry over).

  Job-command collaborators (`ClaudeNotify.JobStore`,
  `ClaudeNotify.JobSupervisor`, `ClaudeNotify.ProjectRegistry`, and the
  Telegram client) are read from GenServer state rather than hardcoded, so
  tests can substitute isolated instances - mirroring the same
  `opts`-with-defaults pattern `ClaudeNotify.JobReconciler.run/1` already
  uses. Production callers never need to pass any of this; see `init/1` for
  the defaults.

  ## Watch mode

  Opt-in per job, off by default (quiet mode): tapping a job's activity
  message's [Watch] button, or `/watch <id>`, sends ONE additional message -
  a live snapshot of `ClaudeNotify.JobTranscript.transcript/3` for that job -
  and edits that same message in place as new entries arrive, throttled to
  at most one edit per `:claude_notify, :watch_edit_interval_ms` (default
  2000ms; a burst of events within the window coalesces into a single
  trailing edit, same throttle shape as `ClaudeNotify.ActivityTracker`).
  [Unwatch] (or `/unwatch <id>`) cancels any pending edit and finalizes the
  transcript message with its current content; a job completing while
  watched finalizes it too, using the transcript snapshot
  `ClaudeNotify.JobRunner` hands the `:completed` notifier event with -
  never a fresh read, since `JobTranscript` discards a job's entries right
  after that same synchronous notifier call returns (see
  `ClaudeNotify.JobTranscript`'s moduledoc). Watching an already-terminal
  job replies with a static snapshot if the transcript is still available,
  or an honest "transcript gone" otherwise.

  Per-job watch bookkeeping (`state.watches`: `job_id => %{message_id:,
  dirty:, timer_ref:}`) lives in this GenServer's own state, not a separate
  process - this app never watches more than a handful of jobs at once.
  Since the job progress/completion notifier runs INSIDE the job's own
  `ClaudeNotify.JobRunner` process (see `default_job_notifier/1`), it
  reaches back into THIS process's live state via a plain `send/2` to
  `self()` captured at launch time, handled by the `:watch_progress` /
  `:watch_completed` `handle_info/2` clauses below - not by touching
  `state` inside the notifier closure directly, which would only be a
  stale, launch-time snapshot.
  """

  use GenServer

  require Logger

  alias ClaudeNotify.{
    Telegram,
    SessionStore,
    TerminalInjector,
    MessageFormatter,
    Dashboard,
    JobStore,
    JobSupervisor,
    JobTranscript,
    PreviewManager,
    ProjectRegistry,
    ProjectScope,
    WorktreeManager
  }

  alias ClaudeNotify.WorktreeManager.Worktree

  @poll_timeout 30
  @known_engines ["claude", "codex"]
  @project_page_size 8
  @max_retry_delay 15_000

  # Single source of truth for the bot's command surface: both
  # `register_bot_commands/1` (Telegram's native "/" menu, via
  # `Telegram.set_my_commands/2`) and `send_help/1` (the `/help` text) render
  # from this list, so the two can't drift out of sync. Mirrors the command
  # table in README.md - keep both in step when a command's behavior changes.
  #
  # `/cancel` has dual behavior (bare = session escape, with a job id =
  # dispatcher job cancel - see the "Job commands" moduledoc section above);
  # Telegram only allows one description per command name, so its entry
  # covers both briefly instead of getting two menu rows.
  @bot_commands [
    {"new", "Choose a project and start a task"},
    {"sessions", "List and select terminal sessions, including idle"},
    {"approve", "Send Yes to the selected session"},
    {"cancel", "Send Escape to the selected session, or cancel a job by id"},
    {"dashboard", "Show Claude Code and Codex sessions and jobs"},
    {"run", "Launch a dispatcher job: [claude|codex] <project> <prompt>"},
    {"jobs", "List known dispatcher jobs and their status"},
    {"projects", "Choose a project working directory"},
    {"watch", "Watch a dispatcher job's live transcript"},
    {"unwatch", "Stop watching a dispatcher job"},
    {"preview", "Open a secure web preview for a job"},
    {"previews", "List active web previews"},
    {"unpreview", "Stop and remove a web preview"},
    {"help", "Show available commands"}
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("TelegramPoller: starting with long polling")
    pid_file = ensure_pid_lock()
    send(self(), :register_commands)
    send(self(), :poll)

    {:ok,
     %{
       offset: 0,
       selected_sessions: %{},
       selected_projects: %{},
       selected_engines: %{},
       telegram: Keyword.get(opts, :telegram, Telegram),
       terminal_injector: Keyword.get(opts, :terminal_injector, TerminalInjector),
       job_store: Keyword.get(opts, :job_store, JobStore),
       job_transcript: Keyword.get(opts, :job_transcript, JobTranscript),
       project_registry: Keyword.get(opts, :project_registry),
       job_launch_opts: Keyword.get(opts, :job_launch_opts, []),
       preview_module: Keyword.get(opts, :preview_module, PreviewManager),
       preview_manager: Keyword.get(opts, :preview_manager, PreviewManager),
       cmd_runner: Keyword.get(opts, :cmd_runner, &default_cmd_runner/3),
       watches: %{},
       attempt: 0,
       pid_file: pid_file
     }}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("TelegramPoller: terminating (#{inspect(reason)})")
    release_pid_lock(state[:pid_file])
    :ok
  end

  @impl true
  def handle_info(:register_commands, state) do
    case register_bot_commands(state.telegram) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning("TelegramPoller: setMyCommands failed: #{inspect(other)}")
    end

    {:noreply, state}
  end

  def handle_info(:poll, state) do
    case Telegram.get_updates(state.offset, @poll_timeout) do
      {:ok, []} ->
        send(self(), :poll)
        {:noreply, %{state | attempt: 0}}

      {:ok, updates} ->
        {new_offset, new_state} = process_updates(updates, state)
        send(self(), :poll)
        {:noreply, %{new_state | offset: new_offset, attempt: 0}}

      {:error, reason} ->
        attempt = state.attempt + 1
        delay = min(1_000 * attempt, @max_retry_delay)
        log_poll_error(reason, attempt, delay)
        Process.send_after(self(), :poll, delay)
        {:noreply, %{state | attempt: attempt}}
    end
  end

  # -- Watch mode (see moduledoc): notifier -> self() plumbing --

  # Sent by `default_job_notifier/1` on every `:progress` event for ANY
  # job (watched or not) - `schedule_watch_flush/2` is a no-op unless
  # `job_id` is actually in `state.watches`, so an unwatched job causes
  # zero extra Telegram calls (just this cheap map lookup).
  @impl true
  def handle_info({:watch_progress, job_id}, state) do
    {:noreply, schedule_watch_flush(state, job_id)}
  end

  # Sent once, right after `handle_job_completed/3` runs, carrying the
  # SAME transcript snapshot `ClaudeNotify.JobRunner` handed the
  # `:completed` notifier event - not re-read here, since by the time this
  # message is actually processed `JobTranscript.discard/2` has already
  # run (see moduledoc).
  @impl true
  def handle_info({:watch_completed, job_id, transcript}, state) do
    {:noreply, finalize_watch_on_completion(state, job_id, transcript)}
  end

  # The trailing edit of a throttled watch: fires `watch_edit_interval_ms`
  # after the first progress event since the last flush.
  @impl true
  def handle_info({:watch_flush, job_id}, state) do
    {:noreply, flush_watch(state, job_id)}
  end

  defp log_poll_error({409, _body}, attempt, delay), do: log_409(attempt, delay)

  defp log_poll_error(reason, attempt, delay) do
    Logger.warning(
      "TelegramPoller: poll failed: #{inspect(reason)}, " <>
        "attempt #{attempt}, retrying in #{div(delay, 1_000)}s"
    )
  end

  defp log_409(attempt, delay) do
    hint =
      if attempt == 1,
        do:
          " — another poller is holding the bot token (zombie session, or a second instance running?)",
        else: ""

    Logger.warning(
      "TelegramPoller: 409 Conflict#{hint}. " <>
        "attempt #{attempt}, retrying in #{div(delay, 1_000)}s"
    )
  end

  defp process_updates(updates, state) do
    Enum.reduce(updates, {state.offset, state}, fn update, {max_offset, acc_state} ->
      update_id = update["update_id"]
      new_state = handle_update(update, acc_state)
      {max(max_offset, update_id + 1), new_state}
    end)
  end

  # Public (but undocumented) so tests can drive a single raw Telegram
  # update through the exact same path :poll uses, without a real network
  # round trip - same rationale as authorized_chat?/1 below.
  @doc false
  def handle_update(%{"callback_query" => callback_query}, state)
      when not is_nil(callback_query) do
    handle_callback(callback_query, state)
  end

  def handle_update(%{"message" => message}, state) when not is_nil(message) do
    handle_message(message, state)
  end

  def handle_update(_update, state), do: state

  # Public (but undocumented) for the same reason handle_update/2 above is:
  # lets tests assert register_bot_commands/1 and send_help/1 both render
  # from this exact list without duplicating it or reaching into a private
  # module attribute.
  @doc false
  def bot_commands, do: @bot_commands

  # --- Callback query handling (button presses) ---

  defp handle_callback(callback_query, state) do
    callback_id = callback_query["id"]
    data = callback_query["data"]
    chat_id = get_in(callback_query, ["message", "chat", "id"])
    message_id = get_in(callback_query, ["message", "message_id"])

    if not authorized_chat?(chat_id) do
      Logger.warning(
        "TelegramPoller: unauthorized callback query",
        event: "unauthorized_telegram_callback",
        chat_id: inspect(chat_id)
      )

      Telegram.answer_callback_query(callback_id, "Unauthorized")
      state
    else
      Logger.info("TelegramPoller: callback: #{data}")

      case parse_callback_data(data) do
        {:nav, :new} ->
          Telegram.answer_callback_query(callback_id, "Choose a project")
          send_project_picker(chat_id, state, 0)
          state

        {:nav, :sessions} ->
          Telegram.answer_callback_query(callback_id, "Open sessions")
          send_session_list(chat_id)
          state

        {:nav, :jobs} ->
          Telegram.answer_callback_query(callback_id, "Recent jobs")
          handle_jobs_command(state)

        {:projects_page, page} ->
          Telegram.answer_callback_query(callback_id, "Projects")
          send_project_picker(chat_id, state, page)
          state

        {:project, token} ->
          handle_project_select(callback_id, chat_id, token, state)

        {:engine, engine} ->
          handle_engine_select(callback_id, chat_id, engine, state)

        {:select, session_id} ->
          Telegram.answer_callback_query(callback_id, "Session selected")
          handle_session_select(chat_id, session_id, state)

        {:dash_refresh} ->
          Telegram.answer_callback_query(callback_id, "Refreshing...")
          Dashboard.refresh()
          state

        {:see_more, session_id} ->
          handle_see_more(callback_id, message_id, session_id)
          state

        {:response, session_id, response} ->
          Telegram.answer_callback_query(callback_id, response_label(response))
          inject_response(state, session_id, response)
          state

        {:job_diff, job_id} ->
          Telegram.answer_callback_query(callback_id, "Fetching diff...")
          handle_job_diff(job_id, state)

        {:job_show_output, job_id} ->
          Telegram.answer_callback_query(callback_id, "Fetching output...")
          handle_job_show_output(job_id, state)

        {:job_create_pr, job_id} ->
          Telegram.answer_callback_query(callback_id, "Creating PR...")
          handle_job_create_pr(job_id, state)

        {:job_discard, job_id} ->
          Telegram.answer_callback_query(callback_id, "Discarding...")
          handle_job_discard(job_id, state)

        {:job_watch, job_id} ->
          Telegram.answer_callback_query(callback_id, "Watching...")
          handle_job_watch(job_id, state)

        {:job_unwatch, job_id} ->
          Telegram.answer_callback_query(callback_id, "Unwatched")
          handle_job_unwatch(job_id, state)

        {:job_preview, job_id} ->
          Telegram.answer_callback_query(callback_id, "Creating preview...")
          handle_preview_job(job_id, state)

        :error ->
          Telegram.answer_callback_query(callback_id, "Invalid action")
          state
      end
    end
  end

  defp handle_see_more(callback_id, message_id, session_id) do
    case message_id && SessionStore.get_notification_text(message_id) do
      nil ->
        Telegram.answer_callback_query(callback_id, "Full text no longer available")

      full_text ->
        # Re-render with the original action buttons (no See more this time).
        buttons =
          [
            ["Yes", "#{session_id}:yes"],
            ["Yes (don't ask)", "#{session_id}:yes_dont_ask"],
            ["No", "#{session_id}:no"],
            ["Esc", "#{session_id}:escape"]
          ]
          |> Enum.map(fn [label, data] -> %{text: label, callback_data: data} end)

        body = %{
          chat_id: Application.get_env(:claude_notify, :telegram_chat_id),
          message_id: message_id,
          text: full_text,
          parse_mode: "MarkdownV2",
          reply_markup: %{inline_keyboard: [buttons]}
        }

        case Telegram.api_post_public("editMessageText", body) do
          {:ok, _} ->
            Telegram.answer_callback_query(callback_id, "Expanded")

          other ->
            Logger.warning("TelegramPoller: See more edit failed: #{inspect(other)}")
            Telegram.answer_callback_query(callback_id, "Edit failed")
        end
    end
  end

  # --- Text message handling ---

  defp handle_message(message, state) do
    chat_id = get_in(message, ["chat", "id"])

    if not authorized_chat?(chat_id) do
      Logger.warning(
        "TelegramPoller: unauthorized message",
        event: "unauthorized_telegram_message",
        chat_id: inspect(chat_id)
      )

      state
    else
      acknowledge_inbound(chat_id, message)

      case message do
        %{"text" => text, "reply_to_message" => %{"message_id" => reply_mid}}
        when is_binary(text) and text != "" ->
          handle_reply_to(chat_id, String.trim(text), reply_mid, state)

        %{"photo" => photos} when is_list(photos) and photos != [] ->
          handle_photo(chat_id, message, state)

        %{"document" => doc} when is_map(doc) ->
          handle_document(chat_id, message, state)

        %{"text" => text} when is_binary(text) ->
          handle_text_command(chat_id, text, state)

        _ ->
          Telegram.send_message(
            MessageFormatter.escape_full(
              "Unsupported message type. Send text, photos, or documents."
            )
          )

          state
      end
    end
  end

  # Fires typing indicator + optional ack reaction on every gated inbound
  # message. Telegram displays "typing…" for ~5s or until our next message.
  defp acknowledge_inbound(chat_id, message) do
    Telegram.send_chat_action(chat_id, "typing")

    case Application.get_env(:claude_notify, :telegram_ack_reaction) do
      emoji when is_binary(emoji) and emoji != "" ->
        case message["message_id"] do
          mid when is_integer(mid) -> Telegram.set_message_reaction(mid, emoji)
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp handle_reply_to(chat_id, text, reply_message_id, state) do
    case SessionStore.lookup_session_by_message(reply_message_id) do
      nil ->
        # Not a tracked terminal-session message - try a job message next.
        handle_reply_to_job(chat_id, text, reply_message_id, state)

      session_id ->
        session = SessionStore.get_session(session_id)

        if session do
          case shortcut_response(text) do
            nil ->
              inject_reply_text(text, session)

            response ->
              if inject_response(state, session_id, response) == :ok do
                short = String.slice(session_id, 0, 8)

                state.telegram.send_message_with_retry(
                  MessageFormatter.escape_full("#{response_label(response)} (#{short})")
                )
              end
          end

          state
        else
          # Session expired, fall back to text command
          handle_text_command(chat_id, text, state)
        end
    end
  end

  # --- Reply-to-job routing (resume) ---

  defp handle_reply_to_job(chat_id, text, reply_message_id, state) do
    case find_job_by_message(state.job_store, reply_message_id) do
      nil ->
        # Not a tracked job message either, treat as a regular text command.
        handle_text_command(chat_id, text, state)

      job ->
        resume_job(job, text, state)
    end
  end

  defp find_job_by_message(job_store, message_id) do
    job_store
    |> JobStore.list()
    |> Enum.find(fn job -> message_id in (job.telegram_message_ids || []) end)
  end

  defp resume_job(%{status: status} = job, text, state) when status in [:completed, :failed] do
    case job.engine_session_id do
      nil ->
        state.telegram.send_message_with_retry(
          MessageFormatter.escape_full("Job ##{job.id} has no recorded session to resume from.")
        )

        state

      session_id ->
        launch_resumed_job(job, session_id, text, state)
    end
  end

  defp resume_job(job, _text, state) do
    state.telegram.send_message_with_retry(
      MessageFormatter.escape_full(
        "Job ##{job.id} is #{job.status} and can't be resumed right now."
      )
    )

    state
  end

  defp launch_resumed_job(original_job, session_id, prompt, state) do
    job_store = state.job_store

    {:ok, new_job} =
      JobStore.create(job_store, %{
        engine: original_job.engine,
        project: original_job.project,
        project_id: original_job.project_id,
        prompt: prompt
      })

    send_and_track_activity_message(
      state,
      new_job.id,
      "Job ##{new_job.id} (#{original_job.project}, #{original_job.engine}): " <>
        "resuming job ##{original_job.id}..."
    )

    opts =
      state.job_launch_opts
      |> Keyword.put_new(:job_store, job_store)
      |> Keyword.put_new(:project_registry, registry(state))
      |> Keyword.put_new(:job_transcript, state.job_transcript)
      |> Keyword.put_new(:notifier, default_job_notifier(state))
      |> Keyword.put(:resume_session_id, session_id)

    JobSupervisor.start_job(new_job, opts)
    state
  end

  defp inject_reply_text(text, session) do
    tty_path = session[:tty_path]
    project = ProjectScope.display_name(session)

    case TerminalInjector.send_text(tty_path, text) do
      :ok ->
        Telegram.send_message(MessageFormatter.escape_full("✓ Sent to #{project}"))

      {:error, reason} ->
        Logger.warning("TelegramPoller: reply inject failed: #{inspect(reason)}")
        Telegram.send_message(MessageFormatter.escape_full("Failed to send to #{project}"))
    end
  end

  # Maps standalone or reply text to a button-equivalent response code, or nil
  # for free text.
  # Recognized: yes/y/approve, no/n/deny, esc/escape/cancel, yes!/yda (don't ask),
  # and bare numerics 1-9 for numbered options. Match is case-insensitive after
  # trimming whitespace.
  @doc false
  def shortcut_response(text) when is_binary(text) do
    case text |> String.trim() |> String.downcase() do
      v when v in ~w(y yes approve ok) -> "yes"
      v when v in ~w(yes! yda) -> "yes_dont_ask"
      v when v in ~w(n no deny) -> "no"
      v when v in ~w(esc escape cancel quit) -> "escape"
      <<digit>> when digit in ?1..?9 -> "opt_#{<<digit>>}"
      _ -> nil
    end
  end

  def shortcut_response(_), do: nil

  # --- Attachment handling ---
  #
  # Telegram caps bot downloads at 20MB. We save to ~/.claude_notify/inbox/
  # and reply with the local path, so the user can ask Claude to read it.
  # We deliberately don't auto-inject — the user knows what they want Claude
  # to do with the file.

  defp handle_photo(chat_id, message, state) do
    photos = message["photo"] || []
    # Last element is the largest size.
    case List.last(photos) do
      %{"file_id" => file_id, "file_unique_id" => unique} ->
        case download_attachment(file_id, unique, "jpg") do
          {:ok, path} ->
            send_inbox_reply(chat_id, path, message["caption"])

          {:error, reason} ->
            Logger.warning("TelegramPoller: photo download failed: #{inspect(reason)}")

            Telegram.send_message(
              MessageFormatter.escape_full("Failed to download photo: #{inspect(reason)}")
            )
        end

      _ ->
        :ok
    end

    state
  end

  defp handle_document(chat_id, message, state) do
    case message["document"] do
      %{"file_id" => file_id} = doc ->
        unique = doc["file_unique_id"] || "dl"
        ext = ext_from_filename(doc["file_name"]) || "bin"

        case download_attachment(file_id, unique, ext) do
          {:ok, path} ->
            send_inbox_reply(chat_id, path, message["caption"])

          {:error, reason} ->
            Logger.warning("TelegramPoller: document download failed: #{inspect(reason)}")

            Telegram.send_message(
              MessageFormatter.escape_full("Failed to download document: #{inspect(reason)}")
            )
        end

      _ ->
        :ok
    end

    state
  end

  defp download_attachment(file_id, unique_id, fallback_ext) do
    with {:ok, %{"file_path" => remote_path}} <- Telegram.get_file(file_id),
         {:ok, body} <- Telegram.download_file(remote_path) do
      ext = ext_from_remote_path(remote_path) || sanitize_segment(fallback_ext) || "bin"
      safe_unique = sanitize_segment(unique_id) || "dl"
      filename = "#{System.system_time(:millisecond)}-#{safe_unique}.#{ext}"
      path = Path.join(inbox_dir(), filename)
      File.mkdir_p!(inbox_dir())
      File.write!(path, body)
      {:ok, path}
    end
  end

  defp send_inbox_reply(chat_id, path, caption) do
    caption_line =
      case caption do
        c when is_binary(c) and c != "" ->
          "\n\nCaption: #{MessageFormatter.escape_full(c)}"

        _ ->
          ""
      end

    text =
      "📎 *Saved attachment*\n\n" <>
        "Path: `#{MessageFormatter.escape_code_public(path)}`" <>
        caption_line <>
        "\n\n" <>
        MessageFormatter.escape_full(
          "Reply to a session message asking Claude to read this path."
        )

    body = %{chat_id: chat_id, text: text, parse_mode: "MarkdownV2"}
    Telegram.api_post_public("sendMessage", body)
  end

  defp inbox_dir do
    Application.get_env(:claude_notify, :inbox_dir) ||
      Path.expand("~/.claude_notify/inbox")
  end

  defp ext_from_filename(name) when is_binary(name) do
    case Path.extname(name) do
      "" -> nil
      "." <> ext -> sanitize_segment(ext)
    end
  end

  defp ext_from_filename(_), do: nil

  defp ext_from_remote_path(path) when is_binary(path) do
    case Path.extname(path) do
      "" -> nil
      "." <> ext -> sanitize_segment(ext)
    end
  end

  defp ext_from_remote_path(_), do: nil

  # Strips anything that isn't a-z, A-Z, 0-9, _, -. Returns nil for empty strings.
  defp sanitize_segment(nil), do: nil

  defp sanitize_segment(segment) when is_binary(segment) do
    case Regex.replace(~r/[^a-zA-Z0-9_-]/, segment, "") do
      "" -> nil
      clean -> clean
    end
  end

  defp handle_text_command(chat_id, text, state) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" ->
        state

      String.starts_with?(trimmed, "/dashboard") ->
        Dashboard.create(chat_id)
        state

      String.starts_with?(trimmed, "/new") ->
        send_project_picker(chat_id, state, 0)
        state

      String.starts_with?(trimmed, "/sessions") or String.starts_with?(trimmed, "/select") ->
        send_session_list(chat_id)
        state

      String.starts_with?(trimmed, "/switch") or trimmed == "/s" ->
        send_session_list(chat_id)
        state

      String.starts_with?(trimmed, "/cancel ") ->
        # "/cancel <job id>" cancels a dispatcher job. Anything else after
        # "/cancel " (not a bare integer) falls through to the existing
        # escape-shortcut clause below, unchanged.
        case trimmed
             |> String.replace_prefix("/cancel ", "")
             |> String.trim()
             |> Integer.parse() do
          {job_id, ""} -> handle_job_cancel(job_id, state)
          _ -> handle_shortcut_command(chat_id, "escape", state)
        end

      String.starts_with?(trimmed, "/cancel") ->
        handle_shortcut_command(chat_id, "escape", state)

      String.starts_with?(trimmed, "/approve") ->
        handle_shortcut_command(chat_id, "yes", state)

      String.starts_with?(trimmed, "/run") ->
        handle_run_command(trimmed, state)

      String.starts_with?(trimmed, "/previews") ->
        handle_previews_command(state)

      String.starts_with?(trimmed, "/unpreview") ->
        handle_unpreview_command(trimmed, state)

      String.starts_with?(trimmed, "/preview") ->
        handle_preview_command(trimmed, state)

      String.starts_with?(trimmed, "/jobs") ->
        handle_jobs_command(state)

      String.starts_with?(trimmed, "/projects") ->
        handle_projects_command(chat_id, state)

      String.starts_with?(trimmed, "/watch") ->
        case parse_watch_id_arg(trimmed, "/watch") do
          {:ok, job_id} ->
            handle_job_watch(job_id, state)

          :error ->
            state.telegram.send_message_with_retry(
              MessageFormatter.escape_full("Usage: /watch <job id>")
            )

            state
        end

      String.starts_with?(trimmed, "/unwatch") ->
        case parse_watch_id_arg(trimmed, "/unwatch") do
          {:ok, job_id} ->
            handle_job_unwatch(job_id, state)

          :error ->
            state.telegram.send_message_with_retry(
              MessageFormatter.escape_full("Usage: /unwatch <job id>")
            )

            state
        end

      String.starts_with?(trimmed, "/start") ->
        send_start(chat_id, state)
        state

      String.starts_with?(trimmed, "/status") ->
        send_status(chat_id, state)
        state

      String.starts_with?(trimmed, "/help") ->
        send_help(chat_id)
        state

      String.starts_with?(trimmed, "/") ->
        # Bot-owned commands are handled above. Everything else belongs to
        # the selected Claude/Codex surface, including project skills such as
        # /post-shorts and built-in interactive commands such as /chrome.
        handle_text_input(chat_id, trimmed, state)

      true ->
        case shortcut_response(trimmed) do
          nil -> handle_text_input(chat_id, trimmed, state)
          response -> handle_shortcut_command(chat_id, response, state)
        end
    end
  end

  # --- Shortcut commands (cancel/approve) ---

  defp handle_shortcut_command(chat_id, response, state) do
    case resolve_session(chat_id, state) do
      {:ok, session_id, state} ->
        if inject_response(state, session_id, response) == :ok do
          label = response_label(response)

          state.telegram.send_message_with_retry(
            MessageFormatter.escape_full("#{label} (#{String.slice(session_id, 0, 8)})")
          )
        end

        state

      {:error, :no_session, state} ->
        state
    end
  end

  # Auto-selects the only known terminal session, including an idle one.
  defp resolve_session(chat_id, state) do
    case Map.get(state.selected_sessions, chat_id) do
      nil ->
        sessions =
          SessionStore.terminal_sessions()
          |> Map.to_list()

        case sessions do
          [{id, _}] ->
            # Auto-select the only open terminal session, even when idle.
            new_selected = Map.put(state.selected_sessions, chat_id, id)
            {:ok, id, %{state | selected_sessions: new_selected}}

          [] ->
            Telegram.send_message(
              MessageFormatter.escape_full(
                "No open terminal sessions. Use /new to choose a project and start a task."
              )
            )

            {:error, :no_session, state}

          _ ->
            Telegram.send_message(
              MessageFormatter.escape_full(
                "Multiple sessions active. Use /sessions to select one first."
              )
            )

            {:error, :no_session, state}
        end

      session_id ->
        case SessionStore.get_session(session_id) do
          nil ->
            Telegram.send_message(
              MessageFormatter.escape_full("Session expired. Use /sessions to pick a new one.")
            )

            new_selected = Map.delete(state.selected_sessions, chat_id)
            {:error, :no_session, %{state | selected_sessions: new_selected}}

          _session ->
            {:ok, session_id, state}
        end
    end
  end

  # --- Session selection ---

  defp handle_session_select(chat_id, session_id, state) do
    case SessionStore.get_session(session_id) do
      nil ->
        Telegram.send_message(MessageFormatter.escape_full("Session not found\\."))
        state

      session ->
        project = ProjectScope.display_name(session)
        short_id = String.slice(session_id, 0, 8)

        text =
          [
            "*Session selected*",
            "",
            "Project: `#{MessageFormatter.escape_code_public(project)}`",
            "ID: `#{MessageFormatter.escape_code_public(short_id)}`",
            "",
            MessageFormatter.escape_full("Type a message and I'll send it to this session.")
          ]
          |> Enum.join("\n")

        Telegram.send_message(text)
        new_selected = Map.put(state.selected_sessions, chat_id, session_id)

        state
        |> Map.put(:selected_sessions, new_selected)
        |> Map.put(
          :selected_projects,
          Map.delete(Map.get(state, :selected_projects, %{}), chat_id)
        )
    end
  end

  # --- Text injection ---

  defp handle_text_input(chat_id, text, state) do
    case Map.get(Map.get(state, :selected_projects, %{}), chat_id) do
      project when is_binary(project) ->
        engine = Map.get(Map.get(state, :selected_engines, %{}), chat_id, "claude")
        launch_job(engine, project, text, state)

      nil ->
        handle_terminal_text_input(chat_id, text, state)
    end
  end

  defp handle_terminal_text_input(chat_id, text, state) do
    case resolve_session(chat_id, state) do
      {:ok, session_id, state} ->
        session = SessionStore.get_session(session_id)
        tty_path = session[:tty_path]
        short_id = String.slice(session_id, 0, 8)
        truncated = String.slice(text, 0, 100)

        case TerminalInjector.send_text(tty_path, text) do
          :ok ->
            Telegram.send_message(
              MessageFormatter.escape_full("Sent to #{short_id}: #{truncated}")
            )

          {:error, reason} ->
            Logger.warning("TelegramPoller: send_text failed: #{inspect(reason)}")

            Telegram.send_message(
              MessageFormatter.escape_full(
                "Failed to send to #{short_id} (tty: #{tty_path || "none"}): #{inspect(reason)}"
              )
            )
        end

        state

      {:error, :no_session, state} ->
        state
    end
  end

  # --- Session list ---

  defp send_session_list(chat_id) do
    sessions =
      SessionStore.terminal_sessions()

    if map_size(sessions) == 0 do
      Telegram.send_message(
        MessageFormatter.escape_full(
          "No open terminal sessions. Use /new to choose a project and start a task."
        )
      )
    else
      buttons =
        Enum.map(sessions, fn {id, session} ->
          project = ProjectScope.display_name(session)
          engine = engine_display_name(session[:engine] || "claude")
          short_id = String.slice(id, 0, 8)
          status = session_status_display(session[:status])
          label = "#{engine} · #{project} · #{status} (#{short_id})"
          [label, "select:#{id}"]
        end)

      # One button per row for readability
      inline_keyboard =
        Enum.map(buttons, fn [label, data] ->
          [%{text: label, callback_data: data}]
        end)

      body = %{
        chat_id: chat_id,
        text:
          "*Terminal Sessions*\n\n#{MessageFormatter.escape_full("Select a working, waiting, or idle session:")}",
        parse_mode: "MarkdownV2",
        reply_markup: %{inline_keyboard: inline_keyboard}
      }

      Telegram.api_post_public("sendMessage", body)
    end
  end

  defp send_help(chat_id) do
    command_lines =
      Enum.map(@bot_commands, fn {command, description} ->
        MessageFormatter.escape_full("/#{command} - #{description}")
      end)

    text =
      (["*Commands*", ""] ++
         command_lines ++
         [
           "",
           MessageFormatter.escape_full("Quick start: /new → choose a project → send your task."),
           MessageFormatter.escape_full(
             "Reply to a completed task to continue its conversation."
           ),
           MessageFormatter.escape_full(
             "Use /sessions when you want to control an open terminal session."
           ),
           MessageFormatter.escape_full(
             "Photos and documents are saved locally; the bot returns a path an agent can read."
           )
         ])
      |> Enum.join("\n")

    body = %{chat_id: chat_id, text: text, parse_mode: "MarkdownV2"}
    Telegram.api_post_public("sendMessage", body)
  end

  # --- Job commands ---

  defp handle_run_command(trimmed, state) do
    case String.split(trimmed, ~r/\s+/, parts: 2) do
      ["/run", rest] ->
        case parse_run_args(rest) do
          {:ok, engine, project, prompt} ->
            launch_job(engine, project, prompt, state)

          :error ->
            send_run_usage(state)
            state
        end

      _ ->
        send_run_usage(state)
        state
    end
  end

  # A registered project literally named "claude" or "codex" is only
  # reachable as the second word, after an explicit engine token - see the
  # moduledoc.
  defp parse_run_args(args) do
    trimmed = String.trim(args)

    case String.split(trimmed, ~r/\s+/, parts: 2) do
      [maybe_engine, rest] when maybe_engine in @known_engines ->
        parse_project_and_prompt(maybe_engine, rest)

      [_first, _rest] ->
        parse_project_and_prompt("claude", trimmed)

      _ ->
        :error
    end
  end

  defp parse_project_and_prompt(engine, text) do
    case String.split(String.trim(text), ~r/\s+/, parts: 2) do
      [project, prompt] when project != "" ->
        case String.trim(prompt) do
          "" -> :error
          trimmed_prompt -> {:ok, engine, project, trimmed_prompt}
        end

      _ ->
        :error
    end
  end

  defp launch_job(engine, project, prompt, state) do
    registry = registry(state)

    case ProjectScope.for_project(registry, project) do
      {:error, {:unknown_project, _name, known}} ->
        send_unknown_project(state, known)
        state

      {:ok, scope} ->
        job_store = state.job_store

        {:ok, job} =
          JobStore.create(job_store, %{
            engine: engine,
            project: scope.name,
            project_id: scope.id,
            prompt: prompt
          })

        send_and_track_activity_message(
          state,
          job.id,
          job_starting_text(job, prompt)
        )

        opts =
          state.job_launch_opts
          |> Keyword.put_new(:job_store, job_store)
          |> Keyword.put_new(:project_registry, registry)
          |> Keyword.put_new(:job_transcript, state.job_transcript)
          |> Keyword.put_new(:notifier, default_job_notifier(state))

        JobSupervisor.start_job(job, opts)
        Dashboard.refresh()
        state
    end
  end

  defp handle_jobs_command(state) do
    jobs = JobStore.list(state.job_store)
    state.telegram.send_message_with_retry(jobs_text(jobs))
    state
  end

  defp handle_preview_command(trimmed, state) do
    case parse_preview_command(trimmed) do
      {:ok, job_id, provider} ->
        handle_preview_job(job_id, state, provider)

      :error ->
        state.telegram.send_message_with_retry(
          MessageFormatter.escape_full("Usage: /preview <job id> [cloudflare|tailscale]")
        )

        state
    end
  end

  defp handle_preview_job(job_id, state, provider \\ nil) do
    case JobStore.get(state.job_store, job_id) do
      nil ->
        state.telegram.send_message_with_retry(
          MessageFormatter.escape_full("Job ##{job_id} not found.")
        )

      job ->
        notify_preparing(state, "typing")

        result =
          if provider do
            preview_module(state).start_preview(preview_manager(state), job, provider)
          else
            preview_module(state).start_preview(preview_manager(state), job)
          end

        case result do
          {:ok, preview} ->
            minutes = max(div(preview.expires_at - System.system_time(:second), 60), 1)

            state.telegram.send_html_with_retry(
              MessageFormatter.agent_markdown_html("""
              **Preview ##{preview.id} is ready**

              [Open job ##{job.id} preview](#{preview.url})

              #{preview_access_message(preview)} Expires in about #{minutes} minutes.
              """)
            )

          {:error, reason} ->
            state.telegram.send_message_with_retry(
              MessageFormatter.escape_full(preview_error(job_id, reason))
            )
        end
    end

    state
  catch
    :exit, reason ->
      state.telegram.send_message_with_retry(
        MessageFormatter.escape_full("Preview service is unavailable: #{inspect(reason)}")
      )

      state
  end

  defp handle_previews_command(state) do
    text =
      case preview_module(state).list(preview_manager(state)) do
        [] ->
          "No active previews. Use /preview <job id> to create one."

        previews ->
          lines =
            Enum.map(previews, fn preview ->
              minutes = max(div(preview.expires_at - System.system_time(:second), 60), 0)

              provider = Map.get(preview, :provider, :cloudflare)

              "- [Preview ##{preview.id} · job ##{preview.job_id}](#{preview.url}) · #{provider} · #{minutes}m left"
            end)

          Enum.join(["**Active previews**", "" | lines], "\n")
      end

    state.telegram.send_html_with_retry(MessageFormatter.agent_markdown_html(text))
    state
  catch
    :exit, reason ->
      state.telegram.send_message_with_retry(
        MessageFormatter.escape_full("Preview service is unavailable: #{inspect(reason)}")
      )

      state
  end

  defp handle_unpreview_command(trimmed, state) do
    case parse_command_id(trimmed, "/unpreview") do
      {:ok, preview_id} ->
        case preview_module(state).stop_preview(preview_manager(state), preview_id) do
          {:ok, preview} ->
            state.telegram.send_message_with_retry(
              MessageFormatter.escape_full(
                "Preview ##{preview.id} stopped. Its local server and remote access route were removed."
              )
            )

          {:error, :not_found} ->
            state.telegram.send_message_with_retry(
              MessageFormatter.escape_full("Preview ##{preview_id} not found.")
            )
        end

      :error ->
        state.telegram.send_message_with_retry(
          MessageFormatter.escape_full("Usage: /unpreview <preview id>")
        )
    end

    state
  catch
    :exit, reason ->
      state.telegram.send_message_with_retry(
        MessageFormatter.escape_full("Preview service is unavailable: #{inspect(reason)}")
      )

      state
  end

  defp parse_command_id(trimmed, command) do
    case String.split(trimmed, ~r/\s+/, parts: 2) do
      [^command, value] ->
        case Integer.parse(String.trim(value)) do
          {id, ""} when id > 0 -> {:ok, id}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_preview_command(trimmed) do
    case String.split(trimmed, ~r/\s+/, trim: true) do
      ["/preview", id] ->
        parse_preview_id(id, nil)

      ["/preview", id, provider] when provider in ["cloudflare", "tailscale"] ->
        parse_preview_id(id, provider)

      _ ->
        :error
    end
  end

  defp parse_preview_id(value, provider) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id, provider}
      _ -> :error
    end
  end

  defp preview_error(_job_id, :not_configured) do
    "No preview provider is configured. Configure Cloudflare Access or install and connect Tailscale, then restart."
  end

  defp preview_error(_job_id, {:provider_not_configured, provider}),
    do: "The #{provider} preview provider is not configured or available."

  defp preview_error(_job_id, :unknown_preview_provider),
    do: "Unknown preview provider. Choose cloudflare or tailscale."

  defp preview_error(job_id, :worktree_missing),
    do: "Job ##{job_id}'s worktree is gone, so it cannot be previewed."

  defp preview_error(_job_id, :preview_command_not_found) do
    "No web app command was detected. Add .claude-notify.json with a preview.command array to the project."
  end

  defp preview_error(_job_id, {:executable_not_found, executable}),
    do: "Preview executable not found: #{executable}."

  defp preview_error(_job_id, :origin_not_ready),
    do: "The web app did not start listening before the preview timeout."

  defp preview_error(_job_id, :origin_exited),
    do: "The web app exited before it became ready."

  defp preview_error(_job_id, :tailscale_port_unavailable),
    do: "No Tailscale HTTPS preview port is available. Stop an existing preview and retry."

  defp preview_error(_job_id, :tailscale_remote_port_unavailable),
    do: "No SSH relay port is available on the configured Tailscale host."

  defp preview_error(_job_id, :tailscale_needs_login),
    do: "The configured Tailscale host needs to sign in before previews can be shared."

  defp preview_error(_job_id, reason),
    do: "Could not create the web preview: #{inspect(reason)}"

  defp preview_access_message(%{access: :otp}),
    do: "Cloudflare Access will email an allowed tester a one-time PIN."

  defp preview_access_message(%{access: :tailnet}),
    do: "Only identities and devices allowed by your Tailscale policy can open it."

  defp preview_access_message(%{access: :public}),
    do: "This uses public Tailscale Funnel access; anyone with the URL can open it."

  defp preview_access_message(_preview), do: "Access is controlled by the preview provider."

  defp preview_module(state), do: Map.get(state, :preview_module, PreviewManager)
  defp preview_manager(state), do: Map.get(state, :preview_manager, PreviewManager)

  defp jobs_text([]) do
    "*Jobs*\n\n" <> MessageFormatter.escape_full("No jobs yet. Use /new to start one.")
  end

  defp jobs_text(jobs) do
    lines =
      Enum.map(jobs, fn job ->
        MessageFormatter.escape_full("##{job.id} #{job.engine} #{job.project} - #{job.status}")
      end)

    Enum.join(["*Jobs*", ""] ++ lines, "\n")
  end

  defp handle_job_cancel(job_id, state) do
    case JobStore.update_status(state.job_store, job_id, :discarded, %{}) do
      {:ok, job} ->
        dynamic_supervisor =
          Keyword.get(state.job_launch_opts, :dynamic_supervisor, JobSupervisor)

        JobSupervisor.stop_job(job_id, dynamic_supervisor: dynamic_supervisor)

        state.telegram.send_message_with_retry(
          MessageFormatter.escape_full("Job ##{job_id} (#{job.project}) cancelled.")
        )

        Dashboard.refresh()
        state

      {:error, {:invalid_transition, from, :discarded}} ->
        state.telegram.send_message_with_retry(
          MessageFormatter.escape_full("Job ##{job_id} is #{from} and can't be cancelled.")
        )

        state

      {:error, :not_found} ->
        state.telegram.send_message_with_retry(
          MessageFormatter.escape_full("Job ##{job_id} not found.")
        )

        state
    end
  end

  defp handle_projects_command(chat_id, state) do
    send_project_picker(chat_id, state, 0)
    state
  end

  defp send_project_picker(_chat_id, state, requested_page) do
    entries = state |> registry() |> ProjectRegistry.entries()

    case entries do
      [] ->
        roots =
          Application.get_env(:claude_notify, :workspace_roots, [])
          |> Enum.map(&friendly_path/1)
          |> Enum.join(", ")

        location = if roots == "", do: "no workspace roots are configured", else: roots

        state.telegram.send_message_with_retry(
          [
            "*No projects found*",
            "",
            MessageFormatter.escape_full("I looked for Git repositories in #{location}."),
            MessageFormatter.escape_full(
              "Set CLAUDE_NOTIFY_WORKSPACE_ROOTS to one or more comma-separated directories, then restart the bot."
            )
          ]
          |> Enum.join("\n")
        )

      _ ->
        page_count = ceil(length(entries) / @project_page_size)
        page = requested_page |> max(0) |> min(page_count - 1)

        project_rows =
          entries
          |> Enum.slice(page * @project_page_size, @project_page_size)
          |> Enum.map(fn entry ->
            [[project_button_label(entry), "project:#{project_token(entry.name)}"]]
          end)

        rows = project_rows ++ project_pagination_rows(page, page_count)

        text =
          [
            "*Choose a project*",
            "",
            MessageFormatter.escape_full(
              "Pick a working directory. Normal messages will start tasks there."
            ),
            MessageFormatter.escape_full("Page #{page + 1} of #{page_count}")
          ]
          |> Enum.join("\n")

        state.telegram.send_with_button_rows_retry(text, rows)
    end
  end

  defp project_pagination_rows(_page, 1), do: []

  defp project_pagination_rows(page, page_count) do
    previous = if page > 0, do: [["‹ Previous", "projects:#{page - 1}"]], else: []
    next = if page + 1 < page_count, do: [["Next ›", "projects:#{page + 1}"]], else: []
    [previous ++ next]
  end

  defp project_button_label(%{name: name, path: path}) do
    parent = path |> Path.dirname() |> Path.basename()
    label = if parent in ["", "/"], do: name, else: "#{name} · #{parent}"
    String.slice(label, 0, 48)
  end

  defp handle_project_select(callback_id, chat_id, token, state) do
    case Enum.find(ProjectRegistry.entries(registry(state)), &(project_token(&1.name) == token)) do
      nil ->
        Telegram.answer_callback_query(callback_id, "Project list changed — choose again")
        send_project_picker(chat_id, state, 0)
        state

      project ->
        engine = Map.get(Map.get(state, :selected_engines, %{}), chat_id, "claude")
        Telegram.answer_callback_query(callback_id, "Working in #{project.name}")

        text =
          [
            "📁 *#{MessageFormatter.escape_full(project.name)}*",
            "`#{MessageFormatter.escape_code_public(friendly_path(project.path))}`",
            "",
            "Agent: *#{engine_display_name(engine)}*",
            "",
            MessageFormatter.escape_full(
              "Send your task as a normal message. Reply to the completed task to continue that conversation."
            )
          ]
          |> Enum.join("\n")

        buttons = engine_buttons(engine)
        state.telegram.send_with_buttons_retry(text, buttons)

        state
        |> Map.put(
          :selected_projects,
          Map.put(Map.get(state, :selected_projects, %{}), chat_id, project.name)
        )
        |> Map.put(
          :selected_engines,
          Map.put(Map.get(state, :selected_engines, %{}), chat_id, engine)
        )
        |> Map.put(
          :selected_sessions,
          Map.delete(Map.get(state, :selected_sessions, %{}), chat_id)
        )
    end
  end

  defp handle_engine_select(callback_id, chat_id, engine, state)
       when engine in @known_engines do
    selected_projects = Map.get(state, :selected_projects, %{})

    case Map.get(selected_projects, chat_id) do
      nil ->
        Telegram.answer_callback_query(callback_id, "Choose a project first")
        send_project_picker(chat_id, state, 0)
        state

      project ->
        Telegram.answer_callback_query(callback_id, "Using #{engine_display_name(engine)}")

        state.telegram.send_message_with_retry(
          MessageFormatter.escape_full(
            "#{engine_display_name(engine)} selected for #{project}. Send your task when ready."
          )
        )

        Map.put(
          state,
          :selected_engines,
          Map.put(Map.get(state, :selected_engines, %{}), chat_id, engine)
        )
    end
  end

  defp engine_buttons(selected) do
    Enum.map(@known_engines, fn engine ->
      marker = if engine == selected, do: "✓ ", else: ""
      ["#{marker}#{engine_display_name(engine)}", "engine:#{engine}"]
    end)
  end

  defp engine_display_name("claude"), do: "Claude"
  defp engine_display_name("codex"), do: "Codex"

  defp friendly_path(path) do
    home = System.user_home!()
    expanded = Path.expand(path)

    if expanded == home or String.starts_with?(expanded, home <> "/"),
      do: "~" <> String.replace_prefix(expanded, home, ""),
      else: expanded
  end

  defp project_token(name) do
    :crypto.hash(:sha256, name)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  defp job_starting_text(job, prompt) do
    preview = prompt |> String.replace(~r/\s+/, " ") |> String.slice(0, 160)

    [
      "⏳ #{job.project} · #{engine_display_name(job.engine)}",
      "Job ##{job.id} · starting",
      "",
      "“#{preview}#{if String.length(prompt) > 160, do: "…", else: ""}”",
      "",
      "I'll keep this message updated."
    ]
    |> Enum.join("\n")
  end

  defp send_run_usage(state) do
    text =
      [
        "*Usage*",
        "",
        MessageFormatter.escape_full("Easiest: use /new, choose a project, then send your task."),
        "",
        MessageFormatter.escape_full("Power-user syntax:"),
        MessageFormatter.escape_full("/run <project> <prompt> - run with Claude"),
        MessageFormatter.escape_full("/run codex <project> <prompt> - run with Codex"),
        MessageFormatter.escape_full("/jobs - list jobs"),
        MessageFormatter.escape_full("/cancel <id> - cancel a job"),
        MessageFormatter.escape_full("/projects - choose a working directory")
      ]
      |> Enum.join("\n")

    state.telegram.send_message_with_retry(text)
  end

  defp send_unknown_project(state, known_projects) do
    known_text =
      case known_projects do
        [] -> "none registered"
        names -> Enum.join(names, ", ")
      end

    state.telegram.send_message_with_retry(
      MessageFormatter.escape_full(
        "I couldn't find that project. Available projects: #{known_text}. Use /projects to choose one."
      )
    )
  end

  # Sends the job's activity message (with a [Watch] button - see the
  # moduledoc's "Watch mode" section) and, if it was sent successfully,
  # stores its message id into the job's telegram_message_ids (so a later
  # reply to that message can be routed back to this job - see
  # `handle_reply_to_job/4`). A Telegram send failure here does not fail the
  # job launch itself; the job proceeds without a tracked message.
  #
  # Only the INITIAL send carries `reply_markup` - the later plain
  # `edit_message_text/2` calls in `handle_job_progress/3` never pass one,
  # and Telegram's `editMessageText` leaves an existing inline keyboard
  # untouched when `reply_markup` is omitted, so the [Watch] button (or
  # [Unwatch], once `set_activity_unwatch_button/2` swaps it - see
  # `begin_live_watch/2`) persists across those edits without this module
  # needing to resend it on every progress tick.
  defp send_and_track_activity_message(state, job_id, text) do
    buttons = [["Watch", "jobwatch:#{job_id}"]]

    case state.telegram.send_with_buttons_retry(MessageFormatter.escape_full(text), buttons) do
      {:ok, %{"result" => %{"message_id" => message_id}}} ->
        JobStore.update(state.job_store, job_id, %{telegram_message_ids: [message_id]})

      _other ->
        :ok
    end
  end

  defp registry(state), do: state.project_registry || ProjectRegistry.load()

  # --- Job progress/completion reporting (ClaudeNotify.JobRunner's notifier) ---

  # Builds the `opts[:notifier]` fun a launched JobRunner calls back into -
  # see ClaudeNotify.JobRunner's moduledoc for the event shapes. Captures
  # `state` as of launch time; `state.telegram`/`state.job_store` don't
  # change over a job's lifetime in practice, and `registry/1` re-resolves
  # a fresh ProjectRegistry on every call when `state.project_registry` is
  # nil (production default), so this stays correct even if the registry is
  # edited between launch and completion.
  #
  # `poller_pid` is captured here (this function always runs inside THIS
  # GenServer's own process) so the closure - which JobRunner actually
  # calls from ITS OWN process - can reach back into this process's LIVE
  # state for watch-mode bookkeeping (`state.watches` can gain/lose this
  # job between launch and now) via a plain `send/2`, handled by the
  # `:watch_progress`/`:watch_completed` `handle_info/2` clauses. The
  # existing `handle_job_progress/3`/`handle_job_completed/3` calls below
  # are unchanged - this only adds a message send alongside them.
  defp default_job_notifier(state) do
    poller_pid = self()

    fn
      {:progress, job_id, progress} ->
        handle_job_progress(state, job_id, progress)
        send(poller_pid, {:watch_progress, job_id})

      {:completed, job_id, result} ->
        handle_job_completed(state, job_id, result)
        Dashboard.refresh()
        send(poller_pid, {:watch_completed, job_id, result.transcript})
    end
  end

  defp handle_job_progress(state, job_id, progress) do
    case JobStore.get(state.job_store, job_id) do
      %{telegram_message_ids: [message_id | _]} = job ->
        text =
          MessageFormatter.activity_message(%{
            project: "Job ##{job.id} (#{job.project}, #{job.engine})",
            action_count: progress.action_count,
            files_touched: progress.files_touched,
            current_tool: progress.current_tool,
            current_detail: progress.current_detail
          })

        state.telegram.edit_message_text_with_retry(message_id, text)
        :ok

      _no_tracked_message ->
        :ok
    end
  end

  defp handle_job_completed(state, job_id, %{status: status, summary: summary}) do
    case JobStore.get(state.job_store, job_id) do
      nil -> :ok
      job -> deliver_completion_report(state, job, status, summary)
    end
  end

  defp deliver_completion_report(state, job, :completed, summary) do
    notify_preparing(state, "typing")
    diffstat = job_diffstat(state, job)
    text = MessageFormatter.job_completed_html(job, diffstat, summary)

    buttons = [
      ["Show diff", "jobdiff:#{job.id}"],
      ["Preview", "jobpreview:#{job.id}"],
      ["Create PR", "jobpr:#{job.id}"],
      ["Discard", "jobdiscard:#{job.id}"]
    ]

    edit_job_report_html(state, job, text, buttons)
  end

  defp deliver_completion_report(state, job, :failed, _summary) do
    notify_preparing(state, "typing")
    text = MessageFormatter.job_failed_html(job, job.error_tail)

    buttons = [
      ["Show output", "jobshowoutput:#{job.id}"],
      ["Discard", "jobdiscard:#{job.id}"]
    ]

    edit_job_report_html(state, job, text, buttons)
  end

  defp edit_job_report(_state, %{telegram_message_ids: []}, _text, _buttons), do: :ok

  defp edit_job_report(state, %{telegram_message_ids: [message_id | _]}, text, buttons) do
    state.telegram.edit_message_text_with_buttons_with_retry(message_id, text, buttons)
    :ok
  end

  defp edit_job_report_html(_state, %{telegram_message_ids: []}, _text, _buttons), do: :ok

  defp edit_job_report_html(state, %{telegram_message_ids: [message_id | _]}, text, buttons) do
    state.telegram.edit_message_text_with_buttons_html_retry(message_id, text, buttons)
    :ok
  end

  # Best-effort "typing…"/"sending a file…" indicator while a job
  # report/diff/output is being formatted and sent - Telegram shows it for
  # ~5s or until the next message from the bot. A failed chat action isn't
  # worth acting on (see `ClaudeNotify.Telegram.send_chat_action/2`), so
  # its result is discarded here exactly like the pre-existing
  # `acknowledge_inbound/2` call does for inbound messages. This app only
  # ever talks to the one chat configured via `:telegram_chat_id` - no
  # per-callback chat_id is threaded through these job handlers, mirroring
  # `handle_see_more/3`'s identical `Application.get_env/2` read.
  defp notify_preparing(state, action) do
    state.telegram.send_chat_action(
      Application.get_env(:claude_notify, :telegram_chat_id),
      action
    )

    :ok
  end

  # --- Job callback handlers (Show diff / Show output / Create PR / Discard) ---

  defp handle_job_diff(job_id, state) do
    case JobStore.get(state.job_store, job_id) do
      nil ->
        state.telegram.send_message_with_retry(
          MessageFormatter.escape_full("Job ##{job_id} not found.")
        )

      job ->
        notify_preparing(state, "upload_document")

        case MessageFormatter.diff_summary(job_diff(state, job, [])) do
          nil ->
            state.telegram.send_message_with_retry(
              MessageFormatter.escape_full("No changes to show.")
            )

          text ->
            state.telegram.send_message_with_retry(text)
        end
    end

    state
  end

  defp handle_job_show_output(job_id, state) do
    case JobStore.get(state.job_store, job_id) do
      nil ->
        state.telegram.send_message_with_retry(
          MessageFormatter.escape_full("Job ##{job_id} not found.")
        )

      job ->
        notify_preparing(state, "upload_document")
        state.telegram.send_message_with_retry(MessageFormatter.job_output_block(job.error_tail))
    end

    state
  end

  defp handle_job_create_pr(job_id, state) do
    case JobStore.get(state.job_store, job_id) do
      nil ->
        state.telegram.send_message_with_retry(
          MessageFormatter.escape_full("Job ##{job_id} not found.")
        )

      job ->
        cond do
          job.status != :completed ->
            state.telegram.send_message_with_retry(
              MessageFormatter.escape_full(
                "Job ##{job.id} is #{job.status}; only a completed job can open a PR."
              )
            )

          not (is_binary(job.worktree_path) and File.dir?(job.worktree_path)) ->
            state.telegram.send_message_with_retry(
              MessageFormatter.escape_full("Job ##{job.id}'s worktree is gone; nothing to push.")
            )

          true ->
            create_pr(state, job)
        end
    end

    state
  end

  # The ONLY place that ever pushes or opens a PR - see the module doc's
  # "Job commands" section. Both the push and `gh pr create` go through
  # `state.cmd_runner`, an injectable `(cmd, args, opts) -> {output, exit_code}`
  # function defaulting to `default_cmd_runner/3` (a thin `System.cmd/3`
  # wrapper), so tests can prove this path is never reached before the
  # callback fires without ever shelling out to a real `git push`/`gh`.
  defp create_pr(state, job) do
    case state.cmd_runner.("git", ["push", "-u", "origin", job.branch], cwd: job.worktree_path) do
      {_output, 0} ->
        run_gh_pr_create(state, job)

      {output, code} ->
        Logger.error(
          "TelegramPoller: git push failed for job #{job.id} (exit #{code}): #{output}"
        )

        state.telegram.send_message_with_retry(
          MessageFormatter.escape_full("Job ##{job.id}: git push failed.")
        )
    end
  end

  defp run_gh_pr_create(state, job) do
    args = ["pr", "create", "--title", pr_title(job), "--body", pr_body(job)]

    case state.cmd_runner.("gh", args, cwd: job.worktree_path) do
      {output, 0} ->
        url = output |> String.trim() |> String.split("\n") |> List.last()

        state.telegram.send_message_with_retry(
          MessageFormatter.escape_full("Job ##{job.id}: PR - #{url}")
        )

      {output, code} ->
        Logger.error(
          "TelegramPoller: gh pr create failed for job #{job.id} (exit #{code}): #{output}"
        )

        state.telegram.send_message_with_retry(
          MessageFormatter.escape_full(
            "Job ##{job.id}: git push succeeded but gh pr create failed."
          )
        )
    end
  end

  defp pr_title(job), do: "Job ##{job.id}: #{String.slice(job.prompt, 0, 72)}"

  defp pr_body(job) do
    "Automated PR for dispatcher job ##{job.id} (#{job.project}, #{job.engine}).\n\nPrompt:\n#{job.prompt}"
  end

  defp handle_job_discard(job_id, state) do
    case JobStore.get(state.job_store, job_id) do
      nil ->
        state.telegram.send_message_with_retry(
          MessageFormatter.escape_full("Job ##{job_id} not found.")
        )

      job ->
        discard_job(state, job)
    end

    state
  end

  # A job still in one of these statuses can genuinely transition to
  # :discarded (see JobStore's @transitions) - drive that transition too, not
  # just the worktree cleanup, mirroring the existing /cancel handler.
  defp discard_job(state, %{status: status} = job)
       when status in [:queued, :running, :awaiting_input] do
    case JobStore.update_status(state.job_store, job.id, :discarded, %{}) do
      {:ok, updated_job} ->
        discard_worktree_and_report(state, updated_job)
        Dashboard.refresh()

      {:error, reason} ->
        Logger.warning("TelegramPoller: could not discard job #{job.id}: #{inspect(reason)}")

        state.telegram.send_message_with_retry(
          MessageFormatter.escape_full("Job ##{job.id} could not be discarded.")
        )
    end
  end

  # :completed/:failed/:discarded have no valid transition to :discarded
  # (JobStore's @transitions map is empty for all three - they're terminal).
  # For an already-completed job, "Discard" cannot mean "change its status":
  # the job DID complete: what the user is discarding is its now-unwanted
  # worktree/branch, not the historical fact that it ran and finished. So
  # this only tears down the worktree and edits the report to say so,
  # leaving `status` exactly as it was.
  defp discard_job(state, job), do: discard_worktree_and_report(state, job)

  defp discard_worktree_and_report(state, job) do
    text = MessageFormatter.escape_full("Job ##{job.id}: worktree discarded.")

    case worktree_for(state, job) do
      nil ->
        edit_job_report(state, job, text, [])

      worktree ->
        case WorktreeManager.discard(worktree) do
          :ok ->
            edit_job_report(state, job, text, [])

          {:error, reason} ->
            Logger.warning(
              "TelegramPoller: worktree discard failed for job #{job.id}: #{inspect(reason)}"
            )

            edit_job_report(
              state,
              job,
              MessageFormatter.escape_full("Job ##{job.id}: failed to discard worktree."),
              []
            )
        end
    end
  end

  defp worktree_for(_state, %{worktree_path: nil}), do: nil

  defp worktree_for(state, job) do
    case ProjectRegistry.lookup(registry(state), job.project) do
      {:ok, repo_path} ->
        %Worktree{
          repo_path: repo_path,
          job_id: to_string(job.id),
          path: job.worktree_path,
          branch: job.branch
        }

      {:error, _reason} ->
        nil
    end
  end

  # --- Watch mode (Watch/Unwatch button + /watch, /unwatch - see moduledoc) ---

  defp handle_job_watch(job_id, state) do
    case JobStore.get(state.job_store, job_id) do
      nil ->
        state.telegram.send_message_with_retry(
          MessageFormatter.escape_full("Job ##{job_id} not found.")
        )

        state

      job ->
        start_watch(state, job)
    end
  end

  defp start_watch(state, job) do
    cond do
      Map.has_key?(state.watches, job.id) ->
        state.telegram.send_message_with_retry(
          MessageFormatter.escape_full("Already watching job ##{job.id}.")
        )

        state

      job.status in [:queued, :running, :awaiting_input] ->
        begin_live_watch(state, job)

      true ->
        send_terminal_snapshot(state, job)
        state
    end
  end

  # A running (or about-to-run) job: send the first transcript message and
  # register `state.watches[job.id]`, so future `:watch_progress` events
  # (see `default_job_notifier/1`) drive throttled edits of THIS message.
  # Also swaps the activity message's [Watch] button for [Unwatch] - see
  # `send_and_track_activity_message/3` for why a plain `edit_message_text/2`
  # progress tick doesn't erase it afterwards.
  defp begin_live_watch(state, job) do
    entries = JobTranscript.transcript(state.job_transcript, job.id)
    text = MessageFormatter.transcript_message(job, entries)

    case state.telegram.send_message_with_retry(text) do
      {:ok, %{"result" => %{"message_id" => message_id}}} ->
        set_activity_button(state, job, "Unwatch", "jobunwatch:#{job.id}")
        watch = %{message_id: message_id, dirty: false, timer_ref: nil}
        %{state | watches: Map.put(state.watches, job.id, watch)}

      _other ->
        state
    end
  end

  # A job that's already terminal (:completed/:failed/:discarded): nothing
  # left to watch, so no `state.watches` entry is registered - either a
  # one-shot static snapshot of whatever transcript is still available, or
  # (the expected case, since `ClaudeNotify.JobRunner` always discards a
  # job's transcript right after its own terminal notifier call - see
  # `ClaudeNotify.JobTranscript`'s moduledoc) an honest "it's gone" reply.
  defp send_terminal_snapshot(state, job) do
    case JobTranscript.transcript(state.job_transcript, job.id) do
      [] ->
        state.telegram.send_message_with_retry(MessageFormatter.transcript_unavailable(job))

      entries ->
        state.telegram.send_message_with_retry(MessageFormatter.transcript_message(job, entries))
    end
  end

  defp handle_job_unwatch(job_id, state) do
    case Map.get(state.watches, job_id) do
      nil ->
        state.telegram.send_message_with_retry(
          MessageFormatter.escape_full("Job ##{job_id} is not being watched.")
        )

        state

      watch ->
        cancel_watch_timer(watch)
        stop_watch(state, job_id, watch)
    end
  end

  # Explicit unwatch: finalizes the transcript message with a FRESH read
  # (the job is not necessarily terminal, unlike `finalize_watch_on_completion/3`
  # below, so there's no discard race to worry about here) and flips the
  # activity message's button back to [Watch] so the job can be re-watched.
  defp stop_watch(state, job_id, watch) do
    case JobStore.get(state.job_store, job_id) do
      nil ->
        :ok

      job ->
        entries = JobTranscript.transcript(state.job_transcript, job_id)
        text = MessageFormatter.transcript_message(job, entries)
        state.telegram.edit_message_text_with_retry(watch.message_id, text)
        set_activity_button(state, job, "Watch", "jobwatch:#{job.id}")
    end

    %{state | watches: Map.delete(state.watches, job_id)}
  end

  # Job completion while watched: finalizes the transcript message using
  # the snapshot `ClaudeNotify.JobRunner` handed the `:completed` notifier
  # event, NOT a fresh `JobTranscript.transcript/2` read - by the time this
  # `handle_info/2`-driven call runs, `JobTranscript.discard/2` has almost
  # certainly already fired (see moduledoc's "Watch mode" section). The
  # activity message itself needs no button flip-back here: the pre-existing
  # completion-report flow (`deliver_completion_report/4`) already replaces
  # its ENTIRE keyboard with the Show diff/Create PR/Discard (or Show
  # output/Discard) buttons.
  defp finalize_watch_on_completion(state, job_id, transcript) do
    case Map.get(state.watches, job_id) do
      nil ->
        state

      watch ->
        cancel_watch_timer(watch)

        case JobStore.get(state.job_store, job_id) do
          nil ->
            :ok

          job ->
            text = MessageFormatter.transcript_message(job, transcript)
            state.telegram.edit_message_text_with_retry(watch.message_id, text)
        end

        %{state | watches: Map.delete(state.watches, job_id)}
    end
  end

  # Trailing-edge throttle, same shape as `ClaudeNotify.ActivityTracker`'s
  # `maybe_schedule_flush/3`: the first `:watch_progress` since the last
  # flush arms a timer; further events before it fires just mark `dirty`,
  # so a burst coalesces into a single edit `watch_edit_interval_ms` later.
  # A no-op when `job_id` isn't currently watched.
  defp schedule_watch_flush(state, job_id) do
    case Map.get(state.watches, job_id) do
      nil ->
        state

      %{timer_ref: nil} = watch ->
        ref = Process.send_after(self(), {:watch_flush, job_id}, watch_edit_interval_ms())
        %{state | watches: Map.put(state.watches, job_id, %{watch | timer_ref: ref, dirty: true})}

      watch ->
        %{state | watches: Map.put(state.watches, job_id, %{watch | dirty: true})}
    end
  end

  defp flush_watch(state, job_id) do
    case Map.get(state.watches, job_id) do
      nil ->
        state

      %{dirty: false} = watch ->
        %{state | watches: Map.put(state.watches, job_id, %{watch | timer_ref: nil})}

      watch ->
        render_and_edit_watch(state, job_id, watch)

        %{
          state
          | watches: Map.put(state.watches, job_id, %{watch | dirty: false, timer_ref: nil})
        }
    end
  end

  defp render_and_edit_watch(state, job_id, watch) do
    case JobStore.get(state.job_store, job_id) do
      nil ->
        :ok

      job ->
        entries = JobTranscript.transcript(state.job_transcript, job_id)
        text = MessageFormatter.transcript_message(job, entries)
        state.telegram.edit_message_text_with_retry(watch.message_id, text)
    end
  end

  defp cancel_watch_timer(%{timer_ref: nil}), do: :ok
  defp cancel_watch_timer(%{timer_ref: ref}), do: Process.cancel_timer(ref)

  defp watch_edit_interval_ms do
    Application.get_env(:claude_notify, :watch_edit_interval_ms, 2_000)
  end

  # Swaps ONLY a job's activity message's inline keyboard (via
  # `Telegram.edit_message_reply_markup/2`) - never touches its text, since
  # the caller doesn't know (and shouldn't need to reconstruct) whatever
  # progress text is currently displayed there.
  defp set_activity_button(state, %{telegram_message_ids: [message_id | _]}, label, data) do
    state.telegram.edit_message_reply_markup_with_retry(message_id, [[label, data]])
  end

  defp set_activity_button(_state, _job, _label, _data), do: :ok

  defp parse_watch_id_arg(trimmed, prefix) do
    trimmed
    |> String.replace_prefix(prefix, "")
    |> String.trim()
    |> Integer.parse()
    |> case do
      {job_id, ""} -> {:ok, job_id}
      _ -> :error
    end
  end

  # --- Job diff/diffstat (read-only `git diff`, no DI needed - only the
  # push/PR path in create_pr/2 needs to be faked in tests) ---

  defp job_diffstat(state, job), do: job_diff(state, job, ["--stat"])

  defp job_diff(_state, %{worktree_path: nil}, _extra_args), do: nil

  defp job_diff(state, job, extra_args) do
    with {:ok, repo_path} <- ProjectRegistry.lookup(registry(state), job.project),
         {:ok, base_branch} <- current_branch(repo_path) do
      args = ["diff"] ++ extra_args ++ ["#{base_branch}...HEAD"]

      case System.cmd("git", args, cd: job.worktree_path, stderr_to_stdout: true) do
        {output, 0} -> output
        {_output, _code} -> nil
      end
    else
      _ -> nil
    end
  end

  defp current_branch(repo_path) do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, code} -> {:error, code}
    end
  end

  defp default_cmd_runner(cmd, args, opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    System.cmd(cmd, args, cd: cwd, stderr_to_stdout: true)
  end

  defp send_start(_chat_id, state) do
    text =
      [
        "*Your coding agent, in Telegram*",
        "",
        MessageFormatter.escape_full(
          "Choose a local project, send a task, and follow Claude or Codex from this chat."
        ),
        "",
        MessageFormatter.escape_full(
          "Your repository stays isolated in a temporary git worktree. Nothing is pushed until you tap Create PR."
        ),
        "",
        MessageFormatter.escape_full("Start by choosing where to work.")
      ]
      |> Enum.join("\n")

    state.telegram.send_with_button_rows_retry(text, [
      [["New task", "nav:new"]],
      [["Open sessions", "nav:sessions"], ["Recent jobs", "nav:jobs"]]
    ])
  end

  defp send_status(chat_id, state) do
    active =
      SessionStore.terminal_sessions()
      |> map_size()

    selected = Map.get(state.selected_sessions, chat_id)
    selected_project = Map.get(Map.get(state, :selected_projects, %{}), chat_id)
    selected_engine = Map.get(Map.get(state, :selected_engines, %{}), chat_id, "claude")

    selected_line =
      case selected && SessionStore.get_session(selected) do
        nil ->
          MessageFormatter.escape_full("Terminal session: none")

        session ->
          project = ProjectScope.display_name(session)
          short = String.slice(selected, 0, 8)

          "Terminal session: `#{MessageFormatter.escape_code_public(project)}` \\(`#{MessageFormatter.escape_code_public(short)}`\\)"
      end

    text =
      [
        "*Status*",
        "",
        MessageFormatter.escape_full("Authorized: yes"),
        MessageFormatter.escape_full("Terminal sessions: #{active}"),
        MessageFormatter.escape_full(
          "New tasks: #{selected_project || "choose with /new"} · #{engine_display_name(selected_engine)}"
        ),
        selected_line
      ]
      |> Enum.join("\n")

    body = %{chat_id: chat_id, text: text, parse_mode: "MarkdownV2"}
    Telegram.api_post_public("sendMessage", body)
  end

  defp register_bot_commands(telegram) do
    commands =
      Enum.map(@bot_commands, fn {command, description} ->
        %{command: command, description: description}
      end)

    telegram.set_my_commands(commands)
  end

  # --- Helpers ---

  defp parse_callback_data("dash:refresh"), do: {:dash_refresh}
  defp parse_callback_data("nav:new"), do: {:nav, :new}
  defp parse_callback_data("nav:sessions"), do: {:nav, :sessions}
  defp parse_callback_data("nav:jobs"), do: {:nav, :jobs}
  defp parse_callback_data("projects:" <> page), do: parse_page_callback(page)
  defp parse_callback_data("project:" <> token) when token != "", do: {:project, token}

  defp parse_callback_data("engine:" <> engine) when engine in @known_engines,
    do: {:engine, engine}

  defp parse_callback_data("jobdiff:" <> id), do: parse_job_callback(:job_diff, id)
  defp parse_callback_data("jobshowoutput:" <> id), do: parse_job_callback(:job_show_output, id)
  defp parse_callback_data("jobpr:" <> id), do: parse_job_callback(:job_create_pr, id)
  defp parse_callback_data("jobdiscard:" <> id), do: parse_job_callback(:job_discard, id)
  defp parse_callback_data("jobwatch:" <> id), do: parse_job_callback(:job_watch, id)
  defp parse_callback_data("jobunwatch:" <> id), do: parse_job_callback(:job_unwatch, id)
  defp parse_callback_data("jobpreview:" <> id), do: parse_job_callback(:job_preview, id)

  defp parse_callback_data(data) when is_binary(data) do
    case String.split(data, ":", parts: 2) do
      ["select", session_id] when session_id != "" ->
        {:select, session_id}

      ["more", session_id] when session_id != "" ->
        {:see_more, session_id}

      [session_id, response] when session_id != "" and response != "" ->
        {:response, session_id, response}

      _ ->
        :error
    end
  end

  defp parse_callback_data(_), do: :error

  defp parse_job_callback(tag, id_str) do
    case Integer.parse(id_str) do
      {id, ""} -> {tag, id}
      _ -> :error
    end
  end

  defp parse_page_callback(page) do
    case Integer.parse(page) do
      {number, ""} when number >= 0 -> {:projects_page, number}
      _ -> :error
    end
  end

  defp inject_response(state, session_id, response) do
    case SessionStore.get_session(session_id) do
      nil ->
        Logger.warning("TelegramPoller: session #{session_id} not found")
        {:error, :session_not_found}

      session ->
        tty_path = session[:tty_path]

        injector = Map.get(state, :terminal_injector, TerminalInjector)

        case injector.send_response(tty_path, response) do
          :ok ->
            :ok

          {:error, reason} ->
            short_id = String.slice(session_id, 0, 8)

            Logger.warning("TelegramPoller: inject failed for #{short_id}: #{inspect(reason)}")

            state.telegram.send_message_with_retry(
              MessageFormatter.escape_full(
                "Failed to inject #{response_label(response)} into #{short_id}"
              )
            )

            {:error, reason}
        end
    end
  end

  defp response_label("yes"), do: "Sent: Yes"
  defp response_label("yes_dont_ask"), do: "Sent: Yes (don't ask)"
  defp response_label("no"), do: "Sent: No"
  defp response_label("escape"), do: "Sent: Escape"
  defp response_label("opt_" <> n), do: "Sent: Option #{n}"
  defp response_label(_), do: "Sent"

  defp session_status_display(:active), do: "working"
  defp session_status_display(:waiting_input), do: "waiting"
  defp session_status_display(:idle), do: "idle"
  defp session_status_display(_status), do: "idle"

  @doc false
  def authorized_chat?(chat_id) do
    configured = Application.get_env(:claude_notify, :telegram_chat_id)
    to_string(chat_id) == to_string(configured)
  end

  # --- PID file lock ---
  #
  # Telegram allows exactly one getUpdates consumer per token. If a previous
  # BEAM crashed (terminal closed, SIGKILL) while polling, its long-poll
  # request can keep the slot held until Telegram times it out. Recording our
  # OS pid here lets a fresh start detect that case and ask the stale process
  # to release the slot.

  defp ensure_pid_lock do
    case pid_file_path() do
      nil ->
        nil

      path ->
        File.mkdir_p!(Path.dirname(path))
        File.chmod(Path.dirname(path), 0o700)
        maybe_evict_stale_holder(path)
        File.write!(path, current_os_pid())
        File.chmod(path, 0o600)
        path
    end
  end

  defp release_pid_lock(nil), do: :ok

  defp release_pid_lock(path) do
    case File.read(path) do
      {:ok, content} ->
        if String.trim(content) == current_os_pid() do
          File.rm(path)
        end

      _ ->
        :ok
    end
  end

  defp maybe_evict_stale_holder(path) do
    with {:ok, content} <- File.read(path),
         {pid, _} <- Integer.parse(String.trim(content)),
         true <- pid > 1,
         true <- to_string(pid) != current_os_pid(),
         true <- process_alive?(pid) do
      Logger.warning(
        "TelegramPoller: replacing stale poller pid=#{pid} (sending SIGTERM to release Telegram long-poll slot)"
      )

      System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)
      # Give Telegram's server-side long poll a moment to drop the previous
      # connection so our first getUpdates doesn't immediately 409.
      Process.sleep(500)
    end
  end

  defp process_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp current_os_pid, do: System.pid()

  defp pid_file_path do
    case Application.get_env(:claude_notify, :poller_pid_file, :default) do
      false -> nil
      :default -> Path.expand("~/.claude_notify/poller.pid")
      path when is_binary(path) -> path
    end
  end
end
