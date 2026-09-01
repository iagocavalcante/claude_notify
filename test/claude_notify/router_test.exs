defmodule ClaudeNotify.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ClaudeNotify.{
    HandoffStore,
    MemoryStore,
    ProjectRegistry,
    ProjectScope,
    ReplayCache,
    Router,
    SessionStore
  }

  @moduletag :tmp_dir

  setup do
    wait_for_event_tasks()
    SessionStore.clear()
    HandoffStore.clear()
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

  test "replay cache has one supervised owner under concurrent first requests" do
    owner = Process.whereis(ReplayCache)

    assert is_pid(owner)
    assert :ets.info(:claude_notify_replay_cache, :owner) == owner

    results =
      1..32
      |> Task.async_stream(
        fn _ -> ReplayCache.check_and_put("concurrent-request", 60) end,
        max_concurrency: 32,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == :replay)) == 31
    assert Process.alive?(owner)
  end

  test "POST /api/context authenticates, claims cross-engine context, and retries idempotently",
       %{
         tmp_dir: tmp_dir
       } do
    repo = create_git_repo(tmp_dir)
    original_registry = ProjectScope.registry()
    registry = %ProjectRegistry{projects: %{"context-project" => repo}, aliases: %{}}
    :ok = ProjectScope.reload(registry)
    on_exit(fn -> ProjectScope.reload(original_registry) end)
    {:ok, scope} = ProjectScope.resolve(repo)

    {:ok, :inserted, handoff} =
      HandoffStore.upsert_automatic(%{
        project_scope: scope,
        source: :terminal,
        source_engine: "claude",
        source_session_id: "claude-source",
        summary: "Continue the portable checkpoint.",
        generation: "stop:one"
      })

    first_payload = %{
      "event" => "session_start",
      "_request" => "startup_context",
      "request_id" => "startup-context-one",
      "session_id" => "codex-receiver",
      "working_dir" => repo,
      "engine" => "codex"
    }

    first = signed_conn("/api/context", first_payload) |> Router.call(Router.init([]))
    assert first.status == 200
    assert first.resp_body =~ "UNTRUSTED HISTORICAL DATA"
    assert first.resp_body =~ "Continue the portable checkpoint"

    retry =
      first_payload
      |> Map.put("request_id", "startup-context-retry")
      |> then(&signed_conn("/api/context", &1))
      |> Router.call(Router.init([]))

    assert retry.status == 200
    assert retry.resp_body == first.resp_body
    assert HandoffStore.get(handoff.id).accepted_by_session_id == "codex-receiver"
  end

  test "POST /api/context requires HMAC and rejects exact request replay", %{tmp_dir: tmp_dir} do
    payload = %{
      "_request" => "startup_context",
      "session_id" => "receiver",
      "working_dir" => tmp_dir,
      "engine" => "claude"
    }

    unsigned =
      conn(:post, "/api/context", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert unsigned.status == 401

    timestamp = System.system_time(:second)
    body = Jason.encode!(payload)

    wrong_domain =
      conn(:post, "/api/context", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-claude-notify-timestamp", Integer.to_string(timestamp))
      |> put_req_header("x-claude-notify-signature", "sha256=#{sign_payload(timestamp, body)}")
      |> Router.call(Router.init([]))

    assert wrong_domain.status == 403

    first = signed_conn("/api/context", payload, timestamp: timestamp)
    assert Router.call(first, Router.init([])).status == 200

    replay = signed_conn("/api/context", payload, timestamp: timestamp)
    assert Router.call(replay, Router.init([])).status == 403
  end

  test "durable capture stays behind the bounded queue and preserves overload responses" do
    :sys.suspend(MemoryStore)

    on_exit(fn ->
      try do
        :sys.resume(MemoryStore)
      catch
        :exit, _ -> :ok
      end
    end)

    max_children = Application.fetch_env!(:claude_notify, :max_event_concurrency)

    statuses =
      for index <- 1..max_children do
        %{
          "event" => "prompt",
          "event_id" => "saturation-#{index}",
          "session_id" => "saturation-#{index}",
          "prompt" => "hold #{index}",
          "working_dir" => File.cwd!()
        }
        |> signed_events_conn()
        |> Router.call(Router.init([]))
        |> Map.fetch!(:status)
      end

    assert Enum.all?(statuses, &(&1 == 202))

    overloaded =
      signed_events_conn(%{
        "event" => "prompt",
        "event_id" => "saturation-overflow",
        "session_id" => "saturation-overflow",
        "prompt" => "overflow",
        "working_dir" => File.cwd!()
      })
      |> Router.call(Router.init([]))

    assert overloaded.status == 503
    assert Jason.decode!(overloaded.resp_body)["error"] == "event queue overloaded"

    :sys.resume(MemoryStore)
    wait_for_event_tasks()
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
    signed_conn("/api/events", payload, opts)
  end

  defp signed_conn(path, payload, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, System.system_time(:second))
    body = Jason.encode!(payload)
    signature = sign_payload(timestamp, body, path)

    conn(:post, path, body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-claude-notify-timestamp", Integer.to_string(timestamp))
    |> put_req_header("x-claude-notify-signature", "sha256=#{signature}")
  end

  defp create_git_repo(tmp_dir) do
    path = Path.join(tmp_dir, "context-repo")
    File.mkdir_p!(path)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: path)
    path
  end

  defp sign_payload(timestamp, body, path \\ "/api/events") do
    secret = Application.fetch_env!(:claude_notify, :webhook_secret)

    message =
      if path == "/api/context", do: "#{timestamp}.#{path}.#{body}", else: "#{timestamp}.#{body}"

    :crypto.mac(:hmac, :sha256, secret, message)
    |> Base.encode16(case: :lower)
  end

  defp wait_for_event_tasks(attempts \\ 300)

  defp wait_for_event_tasks(0), do: flunk("event tasks did not drain")

  defp wait_for_event_tasks(attempts) do
    if Task.Supervisor.children(ClaudeNotify.EventTaskSupervisor) == [] do
      :ok
    else
      Process.sleep(10)
      wait_for_event_tasks(attempts - 1)
    end
  end
end
