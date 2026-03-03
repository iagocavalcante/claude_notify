defmodule ClaudeNotify.Router do
  use Plug.Router

  require Logger

  plug(Plug.Logger, log: :debug)
  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    body_reader: {ClaudeNotify.RouterBodyReader, :read_body, []}
  )

  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
  end

  post "/api/events" do
    params = conn.body_params

    with :ok <- ClaudeNotify.EventAuth.verify(conn),
         :ok <- validate_payload(params),
         :ok <- enqueue_event(params) do
      send_resp(conn, 202, Jason.encode!(%{status: "accepted"}))
    else
      {:error, :missing_timestamp} ->
        send_resp(conn, 401, Jason.encode!(%{error: "missing timestamp header"}))

      {:error, :missing_signature} ->
        send_resp(conn, 401, Jason.encode!(%{error: "missing signature header"}))

      {:error, :invalid_signature} ->
        send_resp(conn, 401, Jason.encode!(%{error: "invalid signature"}))

      {:error, :invalid_timestamp} ->
        send_resp(conn, 400, Jason.encode!(%{error: "invalid timestamp header"}))

      {:error, :invalid_signature_format} ->
        send_resp(conn, 400, Jason.encode!(%{error: "invalid signature header format"}))

      {:error, :timestamp_out_of_range} ->
        send_resp(conn, 403, Jason.encode!(%{error: "request timestamp out of range"}))

      {:error, :replay} ->
        send_resp(conn, 403, Jason.encode!(%{error: "replayed request"}))

      {:error, :webhook_secret_not_configured} ->
        Logger.error("Router: webhook secret is not configured")
        send_resp(conn, 503, Jason.encode!(%{error: "webhook auth not configured"}))

      {:error, :missing_raw_body} ->
        send_resp(conn, 400, Jason.encode!(%{error: "missing request body"}))

      {:error, :missing_event_or_session_id} ->
        send_resp(conn, 400, Jason.encode!(%{error: "missing event or session_id"}))

      {:error, :queue_overloaded} ->
        send_resp(conn, 503, Jason.encode!(%{error: "event queue overloaded"}))

      {:error, reason} ->
        Logger.warning("Router: failed to process event request: #{inspect(reason)}")
        send_resp(conn, 400, Jason.encode!(%{error: "invalid request"}))
    end
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "not found"}))
  end

  defp validate_payload(%{"event" => _, "session_id" => _}), do: :ok
  defp validate_payload(_), do: {:error, :missing_event_or_session_id}

  defp enqueue_event(params) do
    case Task.Supervisor.start_child(ClaudeNotify.EventTaskSupervisor, fn ->
           ClaudeNotify.EventHandler.handle_event(params)
         end) do
      {:ok, _pid} -> :ok
      {:error, :max_children} -> {:error, :queue_overloaded}
      {:error, reason} -> {:error, reason}
    end
  end
end
