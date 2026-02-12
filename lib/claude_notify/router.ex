defmodule ClaudeNotify.Router do
  use Plug.Router

  require Logger

  plug(Plug.Logger, log: :debug)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  get "/health" do
    sessions = ClaudeNotify.SessionStore.all_sessions()
    count = map_size(sessions)

    body = Jason.encode!(%{status: "ok", active_sessions: count})
    send_resp(conn, 200, body)
  end

  get "/debug/sessions" do
    sessions = ClaudeNotify.SessionStore.all_sessions()

    summary =
      Enum.map(sessions, fn {id, s} ->
        %{
          id: id,
          tty_path: s[:tty_path],
          transcript_path:
            s[:transcript_path] && "...#{String.slice(s[:transcript_path] || "", -40..-1)}",
          working_dir: s[:working_dir],
          prompt_count: s[:prompt_count]
        }
      end)

    send_resp(conn, 200, Jason.encode!(summary, pretty: true))
  end

  post "/api/events" do
    params = conn.body_params

    case params do
      %{"event" => _, "session_id" => _} ->
        Task.start(fn -> ClaudeNotify.EventHandler.handle_event(params) end)
        send_resp(conn, 202, Jason.encode!(%{status: "accepted"}))

      _ ->
        send_resp(conn, 400, Jason.encode!(%{error: "missing event or session_id"}))
    end
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "not found"}))
  end
end
