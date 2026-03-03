defmodule ClaudeNotify.Dashboard do
  @moduledoc """
  GenServer that maintains an auto-updating dashboard message in Telegram
  showing all active Claude Code sessions with status and quick actions.

  Rate-limits edits to 1 per 5 seconds. Self-heals when the dashboard
  message is deleted (recreates and re-pins).
  """

  use GenServer

  require Logger

  alias ClaudeNotify.{Telegram, SessionStore, MessageFormatter}

  @min_edit_interval 5_000
  @status_icons %{
    active: "🟢",
    waiting_input: "🟡",
    idle: "⚪"
  }

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
      SessionStore.all_sessions()
      |> Enum.reject(fn {id, _} -> id == "unknown" end)
      |> Enum.sort_by(fn {_id, s} ->
        # waiting_input first, then active, then idle
        priority =
          case s[:status] do
            :waiting_input -> 0
            :active -> 1
            _ -> 2
          end

        {priority, -(s[:last_activity] || 0)}
      end)

    now = System.system_time(:second)
    timestamp = format_timestamp(now)

    if sessions == [] do
      text =
        [
          "*Claude Code Dashboard*",
          "",
          MessageFormatter.escape_full("No active sessions."),
          "",
          MessageFormatter.escape_full("Last updated: #{timestamp}")
        ]
        |> Enum.join("\n")

      keyboard = [[%{text: "Refresh", callback_data: "dash:refresh"}]]
      {text, keyboard}
    else
      session_lines =
        Enum.map(sessions, fn {id, s} ->
          project = Path.basename(s[:working_dir] || "unknown")
          short_id = String.slice(id, 0, 8)
          status = s[:status] || :idle
          icon = Map.get(@status_icons, status, "⚪")
          duration = format_duration(now - (s[:started_at] || now))
          prompts = s[:prompt_count] || 0
          last_tool = s[:last_tool]

          status_label =
            case status do
              :active -> "working"
              :waiting_input -> "waiting for input"
              :idle -> "idle"
            end

          last_line =
            if last_tool do
              "Last: #{last_tool}"
            else
              ""
            end

          lines =
            [
              "#{icon} *#{MessageFormatter.escape_full(project)}* `#{MessageFormatter.escape_code_public(short_id)}`",
              MessageFormatter.escape_full(
                "   #{prompts} prompts | #{duration} | #{status_label}"
              )
            ]

          if last_line != "" do
            lines ++ [MessageFormatter.escape_full("   #{last_line}")]
          else
            lines
          end
        end)
        |> Enum.intersperse([""])
        |> List.flatten()

      text =
        (["*Claude Code Dashboard*", ""] ++
           session_lines ++
           [
             "",
             MessageFormatter.escape_full("Updated: #{timestamp}")
           ])
        |> Enum.join("\n")

      # Build select buttons (one per session) + refresh
      select_buttons =
        Enum.map(sessions, fn {id, s} ->
          project = Path.basename(s[:working_dir] || "unknown")
          short_id = String.slice(id, 0, 8)
          [%{text: "#{project} (#{short_id})", callback_data: "select:#{id}"}]
        end)

      keyboard = select_buttons ++ [[%{text: "Refresh", callback_data: "dash:refresh"}]]

      {text, keyboard}
    end
  end

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
