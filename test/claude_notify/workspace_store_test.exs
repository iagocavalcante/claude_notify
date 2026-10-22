defmodule ClaudeNotify.WorkspaceStoreTest do
  use ExUnit.Case, async: true
  alias ClaudeNotify.WorkspaceStore
  @moduletag :tmp_dir

  test "schedules and receipts survive restart, confirmations are consumed once", %{tmp_dir: dir} do
    path = Path.join(dir, "workspace.dat")
    name = :"workspace_#{System.unique_integer([:positive])}"
    {:ok, store} = WorkspaceStore.start_link(name: name, path: path)
    assert {:error, :invalid_entry} = WorkspaceStore.put(store, {:unknown, "one"}, %{})
    assert :ok = WorkspaceStore.put(store, {:schedule, "one"}, %{prompt: "check"})
    assert :ok = WorkspaceStore.put(store, {:voice, "one"}, %{text: "hello"})
    assert {:ok, %{text: "hello"}} = WorkspaceStore.take(store, {:voice, "one"})
    assert {:ok, nil} = WorkspaceStore.take(store, {:voice, "one"})

    for _ <- 1..205,
        do:
          assert(:ok = WorkspaceStore.receipt(store, %{action: "preview", outcome: "succeeded"}))

    GenServer.stop(store)
    {:ok, restored} = WorkspaceStore.start_link(name: name, path: path)
    on_exit(fn -> if Process.alive?(restored), do: GenServer.stop(restored) end)
    assert [{"one", %{prompt: "check"}}] = WorkspaceStore.list(restored, :schedule)
    assert length(WorkspaceStore.get(restored, :receipts)) == 200
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
  end

  test "failed writes do not change in-memory state", %{tmp_dir: dir} do
    name = :"workspace_#{System.unique_integer([:positive])}"
    path = Path.join(dir, "block/entries.dat")
    {:ok, store} = WorkspaceStore.start_link(name: name, path: path)
    File.write!(Path.join(dir, "block"), "file")
    assert {:error, {:persist_failed, _}} = WorkspaceStore.put(store, {:voice, "one"}, %{})
    assert nil == WorkspaceStore.get(store, {:voice, "one"})
  end
end
