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
  `/cancel <id>` cancels one; `/projects` lists registered projects.
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
    ProjectRegistry
  }

  @poll_timeout 30
  @retry_delay 5_000
  @known_engines ["claude", "codex"]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("TelegramPoller: starting with long polling")
    send(self(), :poll)

    {:ok,
     %{
       offset: 0,
       selected_sessions: %{},
       telegram: Keyword.get(opts, :telegram, Telegram),
       job_store: Keyword.get(opts, :job_store, JobStore),
       project_registry: Keyword.get(opts, :project_registry),
       job_launch_opts: Keyword.get(opts, :job_launch_opts, [])
     }}
  end

  @impl true
  def handle_info(:poll, state) do
    case Telegram.get_updates(state.offset, @poll_timeout) do
      {:ok, []} ->
        send(self(), :poll)
        {:noreply, state}

      {:ok, updates} ->
        {new_offset, new_state} = process_updates(updates, state)
        send(self(), :poll)
        {:noreply, %{new_state | offset: new_offset}}

      {:error, reason} ->
        Logger.warning(
          "TelegramPoller: poll failed: #{inspect(reason)}, retrying in #{@retry_delay}ms"
        )

        Process.send_after(self(), :poll, @retry_delay)
        {:noreply, state}
    end
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

  # --- Callback query handling (button presses) ---

  defp handle_callback(callback_query, state) do
    callback_id = callback_query["id"]
    data = callback_query["data"]
    chat_id = get_in(callback_query, ["message", "chat", "id"])

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
        {:select, session_id} ->
          Telegram.answer_callback_query(callback_id, "Session selected")
          handle_session_select(chat_id, session_id, state)

        {:dash_refresh} ->
          Telegram.answer_callback_query(callback_id, "Refreshing...")
          Dashboard.refresh()
          state

        {:response, session_id, response} ->
          Telegram.answer_callback_query(callback_id, response_label(response))
          inject_response(session_id, response)
          state

        :error ->
          Telegram.answer_callback_query(callback_id, "Invalid action")
          state
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
      case message do
        %{"text" => text, "reply_to_message" => %{"message_id" => reply_mid}}
        when is_binary(text) and text != "" ->
          handle_reply_to(chat_id, String.trim(text), reply_mid, state)

        %{"text" => nil} ->
          Telegram.send_message(
            MessageFormatter.escape_full(
              "Only text messages are supported. Use /help for commands."
            )
          )

          state

        %{"text" => text} when is_binary(text) ->
          handle_text_command(chat_id, text, state)

        _ ->
          state
      end
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
          tty_path = session[:tty_path]
          project = Path.basename(session[:working_dir] || "unknown")

          case TerminalInjector.send_text(tty_path, text) do
            :ok ->
              Telegram.send_message(MessageFormatter.escape_full("✓ Sent to #{project}"))

            {:error, reason} ->
              Logger.warning("TelegramPoller: reply inject failed: #{inspect(reason)}")

              Telegram.send_message(MessageFormatter.escape_full("Failed to send to #{project}"))
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
        state.telegram.send_message(
          MessageFormatter.escape_full("Job ##{job.id} has no recorded session to resume from.")
        )

        state

      session_id ->
        launch_resumed_job(job, session_id, text, state)
    end
  end

  defp resume_job(job, _text, state) do
    state.telegram.send_message(
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
      |> Keyword.put(:resume_session_id, session_id)

    JobSupervisor.start_job(new_job, opts)
    state
  end

  defp handle_text_command(chat_id, text, state) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" ->
        state

      String.starts_with?(trimmed, "/dashboard") ->
        Dashboard.create(chat_id)
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

      String.starts_with?(trimmed, "/jobs") ->
        handle_jobs_command(state)

      String.starts_with?(trimmed, "/projects") ->
        handle_projects_command(state)

      String.starts_with?(trimmed, "/help") ->
        send_help(chat_id)
        state

      String.starts_with?(trimmed, "/") ->
        Telegram.send_message(
          MessageFormatter.escape_full("Unknown command. Use /help for available commands.")
        )

        state

      true ->
        handle_text_input(chat_id, trimmed, state)
    end
  end

  # --- Shortcut commands (cancel/approve) ---

  defp handle_shortcut_command(chat_id, response, state) do
    case resolve_session(chat_id, state) do
      {:ok, session_id, state} ->
        inject_response(session_id, response)

        label = response_label(response)

        Telegram.send_message(
          MessageFormatter.escape_full("#{label} (#{String.slice(session_id, 0, 8)})")
        )

        state

      {:error, :no_session, state} ->
        state
    end
  end

  # Auto-selects session when only one is active, otherwise prompts
  defp resolve_session(chat_id, state) do
    case Map.get(state.selected_sessions, chat_id) do
      nil ->
        sessions =
          SessionStore.all_sessions()
          |> Enum.reject(fn {id, _} -> id == "unknown" end)

        case sessions do
          [{id, _}] ->
            # Auto-select the only active session
            new_selected = Map.put(state.selected_sessions, chat_id, id)
            {:ok, id, %{state | selected_sessions: new_selected}}

          [] ->
            Telegram.send_message(MessageFormatter.escape_full("No active sessions."))

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
        project = Path.basename(session[:working_dir] || "unknown")
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
        %{state | selected_sessions: new_selected}
    end
  end

  # --- Text injection ---

  defp handle_text_input(chat_id, text, state) do
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
      SessionStore.all_sessions()
      |> Enum.reject(fn {id, _session} -> id == "unknown" end)
      |> Map.new()

    if map_size(sessions) == 0 do
      Telegram.send_message(MessageFormatter.escape_full("No active sessions."))
    else
      buttons =
        Enum.map(sessions, fn {id, session} ->
          project = Path.basename(session[:working_dir] || "unknown")
          short_id = String.slice(id, 0, 8)
          label = "#{project} (#{short_id})"
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
          "*Active Sessions*\n\n#{MessageFormatter.escape_full("Select a session to send prompts to:")}",
        parse_mode: "MarkdownV2",
        reply_markup: %{inline_keyboard: inline_keyboard}
      }

      Telegram.api_post_public("sendMessage", body)
    end
  end

  defp send_help(chat_id) do
    text =
      [
        "*Commands*",
        "",
        MessageFormatter.escape_full("/sessions - List and select active sessions"),
        MessageFormatter.escape_full("/approve - Send Yes to selected session"),
        MessageFormatter.escape_full("/cancel - Send Escape to selected session"),
        MessageFormatter.escape_full("/dashboard - Show live session dashboard"),
        MessageFormatter.escape_full("/run [claude|codex] <project> <prompt> - launch a job"),
        MessageFormatter.escape_full("/jobs - List jobs"),
        MessageFormatter.escape_full("/cancel <id> - Cancel a job"),
        MessageFormatter.escape_full("/projects - List registered projects"),
        MessageFormatter.escape_full("/help - Show this help"),
        "",
        MessageFormatter.escape_full("Reply to any message to send text to that session."),
        MessageFormatter.escape_full("Reply to a job's message to resume it."),
        MessageFormatter.escape_full("If only one session is active, it's auto-selected.")
      ]
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

    case ProjectRegistry.lookup(registry, project) do
      {:error, {:unknown_project, _name, known}} ->
        send_unknown_project(state, known)
        state

      {:ok, _repo_path} ->
        job_store = state.job_store

        {:ok, job} =
          JobStore.create(job_store, %{engine: engine, project: project, prompt: prompt})

        send_and_track_activity_message(
          state,
          job.id,
          "Job ##{job.id} (#{project}, #{engine}): starting..."
        )

        opts =
          state.job_launch_opts
          |> Keyword.put_new(:job_store, job_store)
          |> Keyword.put_new(:project_registry, registry)

        JobSupervisor.start_job(job, opts)
        state
    end
  end

  defp handle_jobs_command(state) do
    jobs = JobStore.list(state.job_store)
    state.telegram.send_message(jobs_text(jobs))
    state
  end

  defp jobs_text([]) do
    "*Jobs*\n\n" <> MessageFormatter.escape_full("No jobs yet. Use /run to launch one.")
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

        state.telegram.send_message(
          MessageFormatter.escape_full("Job ##{job_id} (#{job.project}) cancelled.")
        )

        state

      {:error, {:invalid_transition, from, :discarded}} ->
        state.telegram.send_message(
          MessageFormatter.escape_full("Job ##{job_id} is #{from} and can't be cancelled.")
        )

        state

      {:error, :not_found} ->
        state.telegram.send_message(MessageFormatter.escape_full("Job ##{job_id} not found."))
        state
    end
  end

  defp handle_projects_command(state) do
    names = state |> registry() |> ProjectRegistry.known_projects()

    text =
      case names do
        [] ->
          "*Projects*\n\n" <> MessageFormatter.escape_full("No projects registered.")

        _ ->
          Enum.join(["*Projects*", ""] ++ Enum.map(names, &MessageFormatter.escape_full/1), "\n")
      end

    state.telegram.send_message(text)
    state
  end

  defp send_run_usage(state) do
    text =
      [
        "*Usage*",
        "",
        MessageFormatter.escape_full("/run <project> <prompt> - launch a claude job"),
        MessageFormatter.escape_full("/run codex <project> <prompt> - launch a codex job"),
        MessageFormatter.escape_full("/jobs - list jobs"),
        MessageFormatter.escape_full("/cancel <id> - cancel a job"),
        MessageFormatter.escape_full("/projects - list registered projects")
      ]
      |> Enum.join("\n")

    state.telegram.send_message(text)
  end

  defp send_unknown_project(state, known_projects) do
    known_text =
      case known_projects do
        [] -> "none registered"
        names -> Enum.join(names, ", ")
      end

    state.telegram.send_message(
      MessageFormatter.escape_full("Unknown project. Known projects: #{known_text}")
    )
  end

  # Sends the job's activity message and, if it was sent successfully,
  # stores its message id into the job's telegram_message_ids (so a later
  # reply to that message can be routed back to this job - see
  # `handle_reply_to_job/4`). A Telegram send failure here does not fail the
  # job launch itself; the job proceeds without a tracked message.
  defp send_and_track_activity_message(state, job_id, text) do
    case state.telegram.send_message(MessageFormatter.escape_full(text)) do
      {:ok, %{"result" => %{"message_id" => message_id}}} ->
        JobStore.update(state.job_store, job_id, %{telegram_message_ids: [message_id]})

      _other ->
        :ok
    end
  end

  defp registry(state), do: state.project_registry || ProjectRegistry.load()

  # --- Helpers ---

  defp parse_callback_data("dash:refresh"), do: {:dash_refresh}

  defp parse_callback_data(data) when is_binary(data) do
    case String.split(data, ":", parts: 2) do
      ["select", session_id] when session_id != "" ->
        {:select, session_id}

      [session_id, response] when session_id != "" and response != "" ->
        {:response, session_id, response}

      _ ->
        :error
    end
  end

  defp parse_callback_data(_), do: :error

  defp inject_response(session_id, response) do
    case SessionStore.get_session(session_id) do
      nil ->
        Logger.warning("TelegramPoller: session #{session_id} not found")

      session ->
        tty_path = session[:tty_path]

        case TerminalInjector.send_response(tty_path, response) do
          :ok ->
            :ok

          {:error, reason} ->
            short_id = String.slice(session_id, 0, 8)

            Logger.warning("TelegramPoller: inject failed for #{short_id}: #{inspect(reason)}")

            Telegram.send_message(
              MessageFormatter.escape_full(
                "Failed to inject #{response_label(response)} into #{short_id}"
              )
            )
        end
    end
  end

  defp response_label("yes"), do: "Sent: Yes"
  defp response_label("yes_dont_ask"), do: "Sent: Yes (don't ask)"
  defp response_label("no"), do: "Sent: No"
  defp response_label("escape"), do: "Sent: Escape"
  defp response_label("opt_" <> n), do: "Sent: Option #{n}"
  defp response_label(_), do: "Sent"

  @doc false
  def authorized_chat?(chat_id) do
    configured = Application.get_env(:claude_notify, :telegram_chat_id)
    to_string(chat_id) == to_string(configured)
  end
end
