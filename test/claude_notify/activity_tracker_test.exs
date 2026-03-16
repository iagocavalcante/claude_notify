defmodule ClaudeNotify.ActivityTrackerTest do
  use ExUnit.Case, async: false

  alias ClaudeNotify.ActivityTracker

  setup do
    test_pid = self()

    send_fn = fn action, args ->
      send(test_pid, {:telegram, action, args})
      {:ok, %{"result" => %{"message_id" => 123}}}
    end

    {:ok, pid} =
      ActivityTracker.start_link(
        send_fn: send_fn,
        throttle_ms: 50,
        name: :"test_tracker_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{tracker: pid}
  end

  test "track_tool creates activity message on first tool event", %{tracker: pid} do
    ActivityTracker.track_tool(pid, "sess-1", %{
      project: "my_app",
      tool_name: "Read",
      tool_detail: "lib/foo.ex"
    })

    assert_receive {:telegram, :send, _}, 200
  end

  test "track_tool edits message on subsequent events", %{tracker: pid} do
    ActivityTracker.track_tool(pid, "sess-1", %{
      project: "my_app",
      tool_name: "Read",
      tool_detail: "lib/foo.ex"
    })

    assert_receive {:telegram, :send, _}, 200

    ActivityTracker.track_tool(pid, "sess-1", %{
      project: "my_app",
      tool_name: "Write",
      tool_detail: "lib/bar.ex"
    })

    assert_receive {:telegram, :edit, _}, 200
  end

  test "pause_session sends waiting message", %{tracker: pid} do
    ActivityTracker.track_tool(pid, "sess-1", %{
      project: "my_app",
      tool_name: "Read",
      tool_detail: "lib/foo.ex"
    })

    assert_receive {:telegram, :send, _}, 200

    ActivityTracker.pause_session(pid, "sess-1")
    assert_receive {:telegram, :edit, _}, 200
  end

  test "resume_session resets state for new activity message", %{tracker: pid} do
    ActivityTracker.track_tool(pid, "sess-1", %{
      project: "my_app",
      tool_name: "Read",
      tool_detail: "lib/foo.ex"
    })

    assert_receive {:telegram, :send, _}, 200

    ActivityTracker.resume_session(pid, "sess-1")

    ActivityTracker.track_tool(pid, "sess-1", %{
      project: "my_app",
      tool_name: "Bash",
      tool_detail: "mix test"
    })

    assert_receive {:telegram, :send, _}, 200
  end

  test "get_state returns current tracking state", %{tracker: pid} do
    ActivityTracker.track_tool(pid, "sess-1", %{
      project: "my_app",
      tool_name: "Edit",
      tool_detail: "lib/foo.ex"
    })

    Process.sleep(100)
    state = ActivityTracker.get_state(pid, "sess-1")
    assert state.action_count == 1
    assert MapSet.member?(state.files_touched, "foo.ex")
  end

  test "end_session cleans up session state", %{tracker: pid} do
    ActivityTracker.track_tool(pid, "sess-1", %{
      project: "my_app",
      tool_name: "Read",
      tool_detail: "lib/foo.ex"
    })

    assert_receive {:telegram, :send, _}, 200

    ActivityTracker.end_session(pid, "sess-1")
    assert ActivityTracker.get_state(pid, "sess-1") == nil
  end
end
