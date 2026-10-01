defmodule ClaudeNotify.KeepAwakeTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.KeepAwake

  test "active and waiting terminal sessions keep the Mac awake" do
    assert KeepAwake.working?(%{"a" => %{status: :active}}, [])
    assert KeepAwake.working?(%{"a" => %{status: :waiting_input}}, [])
  end

  test "idle terminal sessions remain addressable without holding the Mac awake" do
    refute KeepAwake.working?(%{"a" => %{status: :idle}}, [])
  end

  test "idle terminal sessions hold the Mac awake when include_idle is set" do
    assert KeepAwake.working?(%{"a" => %{status: :idle}}, [], [], include_idle: true)
    refute KeepAwake.working?(%{}, [], [], include_idle: true)
  end

  test "releasing the assertion kills the caffeinate OS process" do
    {:ok, pid} =
      KeepAwake.start_link(name: nil, executable: "/bin/sleep", refresh_interval: :timer.hours(1))

    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, :exit_status, args: ["30"]])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    :sys.replace_state(pid, &%{&1 | port: port})

    GenServer.stop(pid)
    Process.sleep(100)
    assert {_, 1} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
  end

  test "unfinished dispatcher jobs keep the Mac awake" do
    for status <- [:queued, :running, :awaiting_input] do
      assert KeepAwake.working?(%{}, [%{status: status}])
    end
  end

  test "finished dispatcher jobs release the sleep assertion" do
    for status <- [:completed, :failed, :discarded] do
      refute KeepAwake.working?(%{}, [%{status: status}])
    end
  end

  test "an active web preview keeps the Mac awake" do
    assert KeepAwake.working?(%{}, [], [%{id: 1}])
  end
end
