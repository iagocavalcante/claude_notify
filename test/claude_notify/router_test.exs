defmodule ClaudeNotify.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ClaudeNotify.{Router, SessionStore, ReplayCache}

  setup do
    SessionStore.clear()
    ReplayCache.clear()
    :ok
  end

  test "GET /health returns 200 with status" do
    conn =
      conn(:get, "/health")
      |> Router.call(Router.init([]))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "ok"
    refute Map.has_key?(body, "active_sessions")
  end

  test "POST /api/events with valid prompt returns 202" do
    conn =
      signed_events_conn(%{
        "event" => "prompt",
        "session_id" => "test-1",
        "prompt" => "hello",
        "working_dir" => "/tmp"
      })

    conn = Router.call(conn, Router.init([]))

    assert conn.status == 202
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "accepted"
  end

  test "POST /api/events with valid stop returns 202" do
    conn =
      signed_events_conn(%{
        "event" => "stop",
        "session_id" => "test-1",
        "stop_reason" => "user_quit"
      })

    conn = Router.call(conn, Router.init([]))

    assert conn.status == 202
  end

  test "POST /api/events with missing fields returns 400" do
    conn = signed_events_conn(%{"event" => "prompt"})
    conn = Router.call(conn, Router.init([]))

    assert conn.status == 400
  end

  test "POST /api/events without signature headers returns 401" do
    body = Jason.encode!(%{"event" => "prompt", "session_id" => "test-1"})

    conn =
      conn(:post, "/api/events", body)
      |> put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 401
  end

  test "POST /api/events with invalid signature format returns 400" do
    body = Jason.encode!(%{"event" => "prompt", "session_id" => "test-1"})
    timestamp = System.system_time(:second)

    conn =
      conn(:post, "/api/events", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-claude-notify-timestamp", Integer.to_string(timestamp))
      |> put_req_header("x-claude-notify-signature", "sha256=bad")
      |> Router.call(Router.init([]))

    assert conn.status == 400
  end

  test "POST /api/events with stale timestamp returns 403" do
    stale = System.system_time(:second) - 10_000
    conn = signed_events_conn(%{"event" => "prompt", "session_id" => "test-1"}, timestamp: stale)
    conn = Router.call(conn, Router.init([]))

    assert conn.status == 403
  end

  test "POST /api/events replay request returns 403" do
    body = %{"event" => "prompt", "session_id" => "test-1", "prompt" => "hello"}
    timestamp = System.system_time(:second)
    signature = sign_payload(timestamp, Jason.encode!(body))

    first_conn =
      conn(:post, "/api/events", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-claude-notify-timestamp", Integer.to_string(timestamp))
      |> put_req_header("x-claude-notify-signature", "sha256=#{signature}")
      |> Router.call(Router.init([]))

    assert first_conn.status == 202

    second_conn =
      conn(:post, "/api/events", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-claude-notify-timestamp", Integer.to_string(timestamp))
      |> put_req_header("x-claude-notify-signature", "sha256=#{signature}")
      |> Router.call(Router.init([]))

    assert second_conn.status == 403
  end

  test "GET /nonexistent returns 404" do
    conn =
      conn(:get, "/nonexistent")
      |> Router.call(Router.init([]))

    assert conn.status == 404
  end

  test "GET /debug/sessions returns 404" do
    conn =
      conn(:get, "/debug/sessions")
      |> Router.call(Router.init([]))

    assert conn.status == 404
  end

  defp signed_events_conn(payload, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, System.system_time(:second))
    body = Jason.encode!(payload)
    signature = sign_payload(timestamp, body)

    conn(:post, "/api/events", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-claude-notify-timestamp", Integer.to_string(timestamp))
    |> put_req_header("x-claude-notify-signature", "sha256=#{signature}")
  end

  defp sign_payload(timestamp, body) do
    secret = Application.fetch_env!(:claude_notify, :webhook_secret)

    :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}")
    |> Base.encode16(case: :lower)
  end
end
