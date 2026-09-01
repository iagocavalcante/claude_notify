defmodule ClaudeNotify.ConversationStoreTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.ConversationStore
  alias ClaudeNotify.ConversationStore.Conversation
  alias ClaudeNotify.JobStore.Job
  alias ClaudeNotify.ProjectScope.Scope

  @moduletag :tmp_dir

  test "selection, job head, and FIFO follow-ups survive a restart", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "conversations.dat")
    {:ok, store} = ConversationStore.start_link(name: nil, path: path)

    assert {:ok, %Conversation{engine: "claude"}} =
             ConversationStore.select_project(store, 42, scope(tmp_dir), "claude")

    assert {:ok, %Conversation{engine: "codex"}} =
             ConversationStore.select_engine(store, 42, "codex")

    assert {:ok, %Conversation{head_job_id: 7}} =
             ConversationStore.bind_job(store, 42, job(7, "codex"))

    assert {:ok, 1} = ConversationStore.enqueue(store, 42, "first follow-up")
    assert {:ok, 2} = ConversationStore.enqueue(store, 42, "second follow-up", "claude")
    GenServer.stop(store)

    {:ok, restored} = ConversationStore.start_link(name: nil, path: path)
    on_exit(fn -> if Process.alive?(restored), do: GenServer.stop(restored) end)

    assert %Conversation{project: "trainer", engine: "codex", head_job_id: 7} =
             ConversationStore.get(restored, "42")

    assert {:ok, %{prompt: "first follow-up", engine: "codex"}} =
             ConversationStore.pop_pending(restored, 42)

    assert {:ok, %{prompt: "second follow-up", engine: "claude"}} =
             ConversationStore.pop_pending(restored, 42)

    assert :empty = ConversationStore.pop_pending(restored, 42)
  end

  test "fresh retains the destination but clears the chain and queue", %{tmp_dir: tmp_dir} do
    store = start_store(tmp_dir)
    ConversationStore.select_project(store, 42, scope(tmp_dir), "claude")
    ConversationStore.bind_job(store, 42, job(1, "claude"))
    ConversationStore.enqueue(store, 42, "later")

    assert {:ok, %Conversation{} = conversation} = ConversationStore.fresh(store, 42)
    assert conversation.project == "trainer"
    assert conversation.engine == "claude"
    assert conversation.head_job_id == nil
    assert conversation.pending == []
  end

  test "bounds the durable queue and preserves valid UTF-8", %{tmp_dir: tmp_dir} do
    store = start_store(tmp_dir, max_pending: 2, max_prompt_bytes: 9)
    ConversationStore.select_project(store, 42, scope(tmp_dir), "claude")

    assert {:ok, 1} = ConversationStore.enqueue(store, 42, String.duplicate("é", 10))
    assert {:ok, 2} = ConversationStore.enqueue(store, 42, "two")
    assert {:error, :queue_full} = ConversationStore.enqueue(store, 42, "three")

    assert {:ok, %{prompt: prompt}} = ConversationStore.pop_pending(store, 42)
    assert byte_size(prompt) <= 9
    assert String.valid?(prompt)
  end

  test "corrupt persisted state fails closed and is not overwritten", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "corrupt-conversations.dat")
    File.write!(path, "not an Erlang term")
    {:ok, store} = ConversationStore.start_link(name: nil, path: path)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)

    assert {:error, {:store_unavailable, :unsafe_or_corrupt_term}} =
             ConversationStore.select_project(store, 42, scope(tmp_dir), "claude")

    assert File.read!(path) == "not an Erlang term"

    assert :ok = ConversationStore.clear(store)

    assert {:ok, %Conversation{}} =
             ConversationStore.select_project(store, 42, scope(tmp_dir), "claude")
  end

  defp start_store(tmp_dir, opts \\ []) do
    name = :"conversation_store_#{System.unique_integer([:positive])}"

    start_supervised!(
      {ConversationStore,
       Keyword.merge([name: name, path: Path.join(tmp_dir, "conversations.dat")], opts)}
    )
  end

  defp scope(tmp_dir) do
    root = Path.join(tmp_dir, "trainer")
    File.mkdir_p!(root)

    %Scope{
      id: "trainer-id",
      name: "trainer",
      repo_root: root,
      cwd: root,
      worktree_root: root,
      git_common_dir: Path.join(root, ".git")
    }
  end

  defp job(id, engine) do
    %Job{
      id: id,
      engine: engine,
      project: "trainer",
      project_id: "trainer-id",
      prompt: "work",
      status: :completed
    }
  end
end
