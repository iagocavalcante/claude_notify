defmodule ClaudeNotify.TaskTrackerTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.TaskTracker

  setup do
    send_log = :ets.new(:send_log, [:bag, :public])

    send_fn = fn action, args ->
      :ets.insert(send_log, {action, args})
      {:ok, %{"result" => %{"message_id" => 1}}}
    end

    {:ok, pid} =
      TaskTracker.start_link(
        name: :"tracker_#{System.unique_integer([:positive])}",
        send_fn: send_fn
      )

    {:ok, pid: pid, send_log: send_log}
  end

  test "track_create adds a task and sends checklist", %{pid: pid, send_log: log} do
    TaskTracker.track_create(pid, "sess-1", %{subject: "Read auth code"})

    # Give it a moment to process
    Process.sleep(50)

    tasks = TaskTracker.get_tasks(pid, "sess-1")
    assert length(tasks) == 1
    assert hd(tasks).subject == "Read auth code"
    assert hd(tasks).status == :pending

    assert :ets.tab2list(log) != []
  end

  test "track_update changes task status", %{pid: pid} do
    TaskTracker.track_create(pid, "sess-1", %{subject: "Write tests"})
    Process.sleep(50)

    TaskTracker.track_update(pid, "sess-1", %{subject: "Write tests", status: "completed"})
    Process.sleep(50)

    tasks = TaskTracker.get_tasks(pid, "sess-1")
    assert hd(tasks).status == :completed
  end

  test "multiple tasks tracked in order", %{pid: pid} do
    TaskTracker.track_create(pid, "sess-1", %{subject: "Task A"})
    TaskTracker.track_create(pid, "sess-1", %{subject: "Task B"})
    TaskTracker.track_create(pid, "sess-1", %{subject: "Task C"})
    Process.sleep(50)

    tasks = TaskTracker.get_tasks(pid, "sess-1")
    assert length(tasks) == 3
    assert Enum.map(tasks, & &1.subject) == ["Task A", "Task B", "Task C"]
  end

  test "track_update with in_progress status", %{pid: pid} do
    TaskTracker.track_create(pid, "sess-1", %{subject: "Do thing"})
    Process.sleep(50)

    TaskTracker.track_update(pid, "sess-1", %{subject: "Do thing", status: "in_progress"})
    Process.sleep(50)

    tasks = TaskTracker.get_tasks(pid, "sess-1")
    assert hd(tasks).status == :in_progress
  end

  test "end_session clears tasks", %{pid: pid} do
    TaskTracker.track_create(pid, "sess-1", %{subject: "Task A"})
    Process.sleep(50)

    TaskTracker.end_session(pid, "sess-1")
    Process.sleep(50)

    assert TaskTracker.get_tasks(pid, "sess-1") == []
  end
end
