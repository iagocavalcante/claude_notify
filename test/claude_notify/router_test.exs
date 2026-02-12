defmodule ClaudeNotify.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ClaudeNotify.{Router, SessionStore}

  setup do
    SessionStore.clear()
    :ok
  end

  test "GET /health returns 200 with status" do
    conn =
      conn(:get, "/health")
      |> Router.call(Router.init([]))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "ok"
    assert body["active_sessions"] == 0
  end

  test "POST /api/events with valid prompt returns 202" do
    conn =
      conn(:post, "/api/events", %{
        "event" => "prompt",
        "session_id" => "test-1",
        "prompt" => "hello",
        "working_dir" => "/tmp"
      })
      |> put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 202
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "accepted"
  end

  test "POST /api/events with valid stop returns 202" do
    conn =
      conn(:post, "/api/events", %{
        "event" => "stop",
        "session_id" => "test-1",
        "stop_reason" => "user_quit"
      })
      |> put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 202
  end

  test "POST /api/events with missing fields returns 400" do
    conn =
      conn(:post, "/api/events", %{"event" => "prompt"})
      |> put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 400
  end

  test "GET /nonexistent returns 404" do
    conn =
      conn(:get, "/nonexistent")
      |> Router.call(Router.init([]))

    assert conn.status == 404
  end
end
