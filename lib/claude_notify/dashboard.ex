defmodule ClaudeNotify.Dashboard do
  @moduledoc """
  GenServer that maintains an auto-updating dashboard message in Telegram
  showing every managed coding-agent activity with status and quick actions:
  Claude Code terminal sessions, queued/running Claude Code and Codex jobs,
  and active provider-backed web previews.

  Rate-limits edits to 1 per 5 seconds. Self-heals when the dashboard
  message is deleted (recreates and re-pins).
  """

  use GenServer

  require Logger

  alias ClaudeNotify.{Telegram, SessionStore, JobStore, MessageFormatter, PreviewManager}

  @min_edit_interval 5_000
  @status_icons %{
    active: "🟢",
    waiting_input: "🟡",
    idle: "⚪",
    queued: "🕓",
    running: "🟢",
    awaiting_input: "🟡"
  }

  @active_job_statuses [:queued, :running, :awaiting_input]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Create or recreate the dashboard for a given chat."
  def create(chat_id) do
    GenServer.cast(__MODULE__, {:create, chat_id})
  end

  @doc "Request a dashboard refresh (debounced)."
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok, %{dashboards: %{}, pending_refresh: false, refresh_timer: nil}}
  end

  @impl true
  def handle_cast({:create, chat_id}, state) do
    state = do_create_dashboard(chat_id, state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    if state.refresh_timer do
      # Already scheduled, mark pending
      {:noreply, %{state | pending_refresh: true}}
    else
      # Refresh now and schedule cooldown
      state = do_refresh_all(state)
      timer = Process.send_after(self(), :refresh_cooldown, @min_edit_interval)
      {:noreply, %{state | refresh_timer: timer, pending_refresh: false}}
    end
  end

  @impl true
  def handle_info(:refresh_cooldown, state) do
    if state.pending_refresh do
      state = do_refresh_all(state)
      timer = Process.send_after(self(), :refresh_cooldown, @min_edit_interval)
      {:noreply, %{state | refresh_timer: timer, pending_refresh: false}}
    else
      {:noreply, %{state | refresh_timer: nil}}
    end
  end

  # --- Internal ---

  defp do_create_dashboard(chat_id, state) do
    {text, keyboard} = build_dashboard_content()

    body = %{
      chat_id: chat_id,
      text: text,
      parse_mode: "MarkdownV2",
      reply_markup: %{inline_keyboard: keyboard}
    }

    case Telegram.api_post_public("sendMessage", body) do
      {:ok, %{"result" => %{"message_id" => msg_id}}} ->
        # Try to pin (may fail if bot lacks permission, that's ok)
        Telegram.api_post_public("pinChatMessage", %{
          chat_id: chat_id,
          message_id: msg_id,
          disable_notification: true
        })

        dashboards = Map.put(state.dashboards, chat_id, msg_id)
        %{state | dashboards: dashboards}

      {:error, reason} ->
        Logger.warning("Dashboard: failed to create: #{inspect(reason)}")
        state
    end
  end

  defp do_refresh_all(state) do
    {text, keyboard} = build_dashboard_content()

    updated_dashboards =
      Enum.reduce(state.dashboards, state.dashboards, fn {chat_id, msg_id}, acc ->
        body = %{
          chat_id: chat_id,
          message_id: msg_id,
          text: text,
          parse_mode: "MarkdownV2",
          reply_markup: %{inline_keyboard: keyboard}
        }

        case Telegram.api_post_public("editMessageText", body) do
          {:ok, _} ->
            acc

          {:error, {400, %{"description" => desc}}}
          when is_binary(desc) ->
            if String.contains?(desc, "message to edit not found") or
                 String.contains?(desc, "message is not modified") do
              if String.contains?(desc, "message to edit not found") do
                Logger.info("Dashboard: message deleted, recreating for chat #{chat_id}")
                # Will be recreated on next create call
                Map.delete(acc, chat_id)
              else
                # Message not modified (content unchanged) - that's fine
                acc
              end
            else
              Logger.warning("Dashboard: edit failed: #{desc}")
              acc
            end

          {:error, {429, %{"parameters" => %{"retry_after" => retry_after}}}} ->
            Logger.warning("Dashboard: rate limited, retrying in #{retry_after}s")
            Process.send_after(self(), :refresh_cooldown, retry_after * 1000)
            acc

          {:error, reason} ->
            Logger.warning("Dashboard: edit failed: #{inspect(reason)}")
            acc
        end
      end)

    %{state | dashboards: updated_dashboards}
  end

  defp build_dashboard_content do
    sessions =
      SessionStore.terminal_sessions()

    jobs =
      if Process.whereis(JobStore) do
        JobStore.list()
        |> Enum.filter(&(&1.status in @active_job_statuses))
      else
        []
      end

    previews =
      if Process.whereis(PreviewManager), do: PreviewManager.list(), else: []

    build_dashboard_content(sessions, jobs, previews, System.system_time(:second))
  end

  @doc false
  def build_dashboard_content(sessions, jobs, now) do
    build_dashboard_content(sessions, jobs, [], now)
  end

  @doc false
  def build_dashboard_content(sessions, jobs, previews, now) do
    sessions = sort_sessions(sessions)
    jobs = jobs |> Enum.filter(&(&1.status in @active_job_statuses)) |> sort_jobs()
    previews = Enum.sort_by(previews, & &1.id)

    timestamp = format_timestamp(now)

    if sessions == [] and jobs == [] and previews == [] do
      text =
        [
          "*Agent Dashboard*",
          "",
          MessageFormatter.escape_full("Nothing is running right now."),
          MessageFormatter.escape_full("Use /new to choose a project and start a task."),
          "",
          MessageFormatter.escape_full("Last updated: #{timestamp}")
        ]
        |> Enum.join("\n")

      keyboard = [
        [%{text: "New task", callback_data: "nav:new"}],
        [%{text: "Refresh", callback_data: "dash:refresh"}]
      ]

      {text, keyboard}
    else
      job_lines = render_job_lines(jobs, now)
      session_lines = render_session_lines(sessions, now)
      preview_lines = render_preview_lines(previews, now)

      summary =
        MessageFormatter.escape_full(
          "#{length(jobs)} agent #{pluralize(length(jobs), "job", "jobs")} · " <>
            "#{length(sessions)} terminal #{pluralize(length(sessions), "session", "sessions")} · " <>
            "#{length(previews)} web #{pluralize(length(previews), "preview", "previews")}"
        )

      text =
        (["*Agent Dashboard*", summary] ++
           section("Agent jobs", job_lines) ++
           section("Terminal sessions", session_lines) ++
           section("Web previews", preview_lines) ++
           [
             "",
             MessageFormatter.escape_full("Updated: #{timestamp}")
           ])
        |> Enum.join("\n")

      job_buttons =
        Enum.map(jobs, fn job ->
          label = "Watch #{engine_name(job.engine)} · #{job.project} ##{job.id}"

          [
            %{
              text: String.slice(label, 0, 60),
              callback_data: "jobwatch:#{job.id}"
            }
          ]
        end)

      session_buttons =
        Enum.map(sessions, fn {id, s} ->
          project = Path.basename(s[:working_dir] || "unknown")
          short_id = String.slice(id, 0, 8)
          [%{text: "Open #{project} · #{short_id}", callback_data: "select:#{id}"}]
        end)

      preview_buttons =
        Enum.map(previews, fn preview ->
          [
            %{
              text: "Open preview ##{preview.id} · job ##{preview.job_id}",
              url: preview.url
            }
          ]
        end)

      keyboard =
        job_buttons ++
          session_buttons ++
          preview_buttons ++
          [
            [%{text: "New task", callback_data: "nav:new"}],
            [%{text: "Refresh", callback_data: "dash:refresh"}]
          ]

      {text, keyboard}
    end
  end

  defp sort_sessions(sessions) do
    Enum.sort_by(sessions, fn {_id, session} ->
      {session_priority(session[:status]), -(session[:last_activity] || 0)}
    end)
  end

  defp sort_jobs(jobs) do
    Enum.sort_by(jobs, fn job ->
      {job_priority(job.status), -(job.updated_at || job.inserted_at || 0), -job.id}
    end)
  end

  defp session_priority(:waiting_input), do: 0
  defp session_priority(:active), do: 1
  defp session_priority(_), do: 2

  defp job_priority(:awaiting_input), do: 0
  defp job_priority(:running), do: 1
  defp job_priority(:queued), do: 2
  defp job_priority(_), do: 3

  defp render_job_lines(jobs, now) do
    jobs
    |> Enum.map(fn job ->
      icon = Map.get(@status_icons, job.status, "⚪")
      duration = format_duration(max(now - (job.inserted_at || now), 0))
      preview = job.prompt |> to_string() |> String.replace(~r/\s+/, " ") |> String.slice(0, 72)

      [
        "#{icon} *#{MessageFormatter.escape_full(engine_name(job.engine))}* · `#{MessageFormatter.escape_code_public(job.project)}`",
        MessageFormatter.escape_full(
          "   Job ##{job.id} · #{job_status_label(job.status)} · #{duration}"
        ),
        MessageFormatter.escape_full("   #{preview}")
      ]
    end)
    |> Enum.intersperse([""])
    |> List.flatten()
  end

  defp render_session_lines(sessions, now) do
    sessions
    |> Enum.map(fn {id, session} ->
      project = Path.basename(session[:working_dir] || "unknown")
      short_id = String.slice(id, 0, 8)
      status = session[:status] || :idle
      icon = Map.get(@status_icons, status, "⚪")
      duration = format_duration(max(now - (session[:started_at] || now), 0))
      prompts = session[:prompt_count] || 0

      details =
        "   Terminal #{short_id} · #{session_status_label(status)} · #{duration} · #{prompts} prompts"

      last_tool =
        case session[:last_tool] do
          nil -> []
          tool -> [MessageFormatter.escape_full("   Last action: #{tool}")]
        end

      [
        "#{icon} *Claude Code* · `#{MessageFormatter.escape_code_public(project)}`",
        MessageFormatter.escape_full(details)
      ] ++ last_tool
    end)
    |> Enum.intersperse([""])
    |> List.flatten()
  end

  defp render_preview_lines(previews, now) do
    Enum.flat_map(previews, fn preview ->
      remaining = format_duration(max((Map.get(preview, :expires_at) || now) - now, 0))
      provider = Map.get(preview, :provider) || :cloudflare
      icon = if Map.get(preview, :access) == :public, do: "🌐", else: "🔐"

      [
        "#{icon} *Web preview* · `#{MessageFormatter.escape_code_public(Map.get(preview, :project) || "job")}`",
        MessageFormatter.escape_full(
          "   Preview ##{preview.id} · job ##{preview.job_id} · #{provider} · #{remaining} left"
        )
      ]
    end)
  end

  defp section(_title, []), do: []
  defp section(title, lines), do: ["", "*#{title}*" | lines]

  defp job_status_label(:queued), do: "queued"
  defp job_status_label(:running), do: "working"
  defp job_status_label(:awaiting_input), do: "waiting for input"
  defp job_status_label(status), do: to_string(status)

  defp session_status_label(:active), do: "working"
  defp session_status_label(:waiting_input), do: "waiting for input"
  defp session_status_label(:idle), do: "idle"
  defp session_status_label(status), do: to_string(status)

  defp engine_name("claude"), do: "Claude Code"
  defp engine_name("codex"), do: "Codex"
  defp engine_name(other), do: other |> to_string() |> String.capitalize()

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_count, _singular, plural), do: plural

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) do
    minutes = div(seconds, 60)

    if minutes < 60 do
      "#{minutes}m"
    else
      hours = div(minutes, 60)
      remaining_min = rem(minutes, 60)
      "#{hours}h #{remaining_min}m"
    end
  end

  defp format_timestamp(unix) do
    {:ok, dt} = DateTime.from_unix(unix)
    Calendar.strftime(dt, "%H:%M:%S UTC")
  end
end
