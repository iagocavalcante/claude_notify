defmodule ClaudeNotify.HandoffStoreTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.HandoffStore
  alias ClaudeNotify.HandoffStore.Handoff
  alias ClaudeNotify.ProjectScope.Scope

  @moduletag :tmp_dir

  defp scope(tmp_dir, project_id \\ "project_one", relative_cwd \\ ".") do
    root = Path.join(tmp_dir, project_id)
    cwd = Path.join(root, relative_cwd)
    File.mkdir_p!(cwd)

    %Scope{
      id: project_id,
      name: project_id,
      repo_root: root,
      cwd: cwd,
      worktree_root: root,
      git_common_dir: Path.join(root, ".git")
    }
  end

  defp attrs(scope, overrides \\ %{}) do
    Map.merge(
      %{
        project_scope: scope,
        source: :terminal,
        source_engine: "claude",
        source_session_id: "source-session",
        summary: "Implemented the durable checkpoint.",
        open_questions: ["Should the index be rebuilt?"],
        next_steps: ["Run the tests."],
        files_touched: ["lib/checkpoint.ex"],
        generation: "stop:1",
        created_at: 1_800_000_000_000
      },
      overrides
    )
  end

  test "automatic generations are idempotent and supersede prior open checkpoints", %{
    tmp_dir: tmp_dir
  } do
    store = start_store(tmp_dir)
    project = scope(tmp_dir)

    assert {:ok, :inserted, %Handoff{state: :open} = first} =
             HandoffStore.upsert_automatic(store, attrs(project))

    assert {:ok, :duplicate, %Handoff{id: first_id}} =
             HandoffStore.upsert_automatic(store, attrs(project, %{summary: "replayed"}))

    assert first_id == first.id

    assert {:ok, :inserted, %Handoff{state: :open} = second} =
             HandoffStore.upsert_automatic(
               store,
               attrs(project, %{generation: "session-end:2", created_at: 1_800_000_001_000})
             )

    assert HandoffStore.get(store, first.id).state == :expired
    assert second.id != first.id
  end

  test "state machine rejects invalid transitions", %{tmp_dir: tmp_dir} do
    store = start_store(tmp_dir)
    {:ok, :inserted, handoff} = HandoffStore.upsert_automatic(store, attrs(scope(tmp_dir)))

    assert {:ok, %Handoff{state: :expired}} =
             HandoffStore.transition(store, handoff.id, :expired)

    assert {:error, {:invalid_transition, :expired, :accepted}} =
             HandoffStore.transition(store, handoff.id, :accepted)
  end

  test "claims are newest-first, path-scoped, source-excluding, and durable across restart", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "handoffs.dat")
    {:ok, store} = HandoffStore.start_link(name: nil, path: path)
    project = scope(tmp_dir, "project_one", "apps/web")
    {:ok, :inserted, inserted} = HandoffStore.upsert_automatic(store, attrs(project))

    assert :none =
             HandoffStore.claim(store, scope(tmp_dir, "project_two", "apps/web"), %{
               session_id: "receiver",
               engine: "codex"
             })

    assert :none =
             HandoffStore.claim(store, scope(tmp_dir, "project_one", "apps/api"), %{
               session_id: "receiver-sibling",
               engine: "codex"
             })

    assert :none =
             HandoffStore.claim(store, scope(tmp_dir, "project_one", "apps/web-other"), %{
               session_id: "receiver-prefix-attack",
               engine: "codex"
             })

    assert :none =
             HandoffStore.claim(store, project, %{
               session_id: "source-session",
               engine: "claude"
             })

    assert {:ok, :claimed, %Handoff{state: :accepted} = claimed} =
             HandoffStore.claim(store, scope(tmp_dir, "project_one", "apps/web/live"), %{
               session_id: "receiver",
               engine: "codex"
             })

    assert claimed.id == inserted.id
    assert claimed.accepted_by_engine == "codex"
    GenServer.stop(store)

    {:ok, restored} = HandoffStore.start_link(name: nil, path: path)
    on_exit(fn -> if Process.alive?(restored), do: GenServer.stop(restored) end)

    assert {:ok, :existing, %Handoff{id: id}} =
             HandoffStore.claim(restored, scope(tmp_dir, "project_one", "apps/web/live"), %{
               session_id: "receiver",
               engine: "codex"
             })

    assert id == inserted.id
  end

  test "bounds text and rejects escaping file paths", %{tmp_dir: tmp_dir} do
    store = start_store(tmp_dir, max_summary_bytes: 12, max_items: 2, max_item_bytes: 10)

    assert {:ok, :inserted, handoff} =
             HandoffStore.upsert_automatic(
               store,
               attrs(scope(tmp_dir), %{
                 summary: String.duplicate("é", 20),
                 files_touched: ["../secret", "/etc/passwd", "lib/a.ex", "lib/b.ex", "lib/c.ex"]
               })
             )

    assert byte_size(handoff.summary) <= 12
    assert String.valid?(handoff.summary)
    assert handoff.files_touched == ["lib/a.ex", "lib/b.ex"]
  end

  test "corrupt persisted state fails closed without crashing", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "corrupt-handoffs.dat")
    File.write!(path, "not an Erlang term")
    {:ok, store} = HandoffStore.start_link(name: nil, path: path)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)

    assert HandoffStore.list(store) == []

    assert {:error, {:store_unavailable, :unsafe_or_corrupt_term}} =
             HandoffStore.upsert_automatic(store, attrs(scope(tmp_dir)))

    assert File.read!(path) == "not an Erlang term"
  end

  defp start_store(tmp_dir, opts \\ []) do
    name = :"handoff_store_#{System.unique_integer([:positive])}"

    start_supervised!(
      {HandoffStore, Keyword.merge([name: name, path: Path.join(tmp_dir, "#{name}.dat")], opts)}
    )

    name
  end
end
