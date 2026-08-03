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
