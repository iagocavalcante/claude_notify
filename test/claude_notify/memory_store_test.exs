defmodule ClaudeNotify.MemoryStoreTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.MemoryStore
  alias ClaudeNotify.MemoryStore.Observation
  alias ClaudeNotify.ProjectScope.Scope

  @moduletag :tmp_dir

  defp scope(tmp_dir, id \\ "project_one") do
    repo = Path.join(tmp_dir, id)
    File.mkdir_p!(repo)

    %Scope{
      id: id,
      name: id,
      repo_root: repo,
      cwd: repo,
      worktree_root: repo,
      git_common_dir: Path.join(repo, ".git")
    }
  end

  defp attrs(tmp_dir, overrides \\ %{}) do
    Map.merge(
      %{
        ingest_key: "event-1",
        project_scope: scope(tmp_dir),
        source: :terminal,
        engine: "claude",
        session_id: "session-1",
        kind: :user_prompt,
        title: "User prompt",
        body: "Fix the tests",
        metadata: %{},
        created_at: 1_800_000_000_000
      },
      overrides
    )
  end

  test "inserts a normalized observation and deduplicates the ingest key", %{tmp_dir: tmp_dir} do
    store = start_store(tmp_dir)

    assert {:ok, :inserted, %Observation{} = observation} =
             MemoryStore.ingest(store, attrs(tmp_dir))

    assert observation.project_id == "project_one"
    assert observation.kind == :user_prompt
    assert observation.created_at == 1_800_000_000_000

    assert {:ok, :duplicate, %Observation{id: duplicate_id}} =
             MemoryStore.ingest(store, attrs(tmp_dir, %{body: "changed replay body"}))

    assert duplicate_id == observation.id
    assert MemoryStore.count(store) == 1
  end

  test "redacts common credentials and enforces UTF-8-safe byte limits", %{tmp_dir: tmp_dir} do
    store =
      start_store(tmp_dir,
        max_title_bytes: 12,
        max_body_bytes: 40,
        max_metadata_entries: 3,
        max_collection_entries: 2
      )

    body = "password=hunter2 Bearer abc.def.ghi sk-abcdefghijklmnop " <> String.duplicate("é", 50)

    assert {:ok, :inserted, observation} =
             MemoryStore.ingest(
               store,
               attrs(tmp_dir, %{
                 title: String.duplicate("title", 10),
                 body: body,
                 metadata: %{
                   "files" => ["one", "two", "three"],
                   "a" => "ok",
                   "m" => "kept"
                 }
               })
             )

    assert byte_size(observation.title) <= 12
    assert byte_size(observation.body) <= 40
    assert String.valid?(observation.body)
    refute observation.body =~ "hunter2"
    refute observation.body =~ "abc.def.ghi"
    assert map_size(observation.metadata) == 3
    assert observation.metadata["files"] == ["one", "two"]
  end

  test "retains bounded bodies while keeping older ingest keys replay-safe", %{tmp_dir: tmp_dir} do
    store = start_store(tmp_dir, max_per_session: 2, max_per_project: 3, max_ingest_keys: 10)

    for index <- 1..3 do
      assert {:ok, :inserted, _} =
               MemoryStore.ingest(
                 store,
                 attrs(tmp_dir, %{ingest_key: "a-#{index}", body: "a#{index}"})
               )
    end

    assert Enum.map(MemoryStore.list(store), & &1.body) == ["a2", "a3"]

    assert {:ok, :duplicate, nil} =
             MemoryStore.ingest(store, attrs(tmp_dir, %{ingest_key: "a-1"}))

    for index <- 1..2 do
      assert {:ok, :inserted, _} =
               MemoryStore.ingest(
                 store,
                 attrs(tmp_dir, %{
                   ingest_key: "b-#{index}",
                   session_id: "session-2",
                   body: "b#{index}"
                 })
               )
    end

    assert Enum.map(MemoryStore.list(store), & &1.body) == ["a3", "b1", "b2"]
  end

  test "persists observations and replay keys across restart", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "memory.dat")
    {:ok, store} = MemoryStore.start_link(name: nil, path: path)
    assert {:ok, :inserted, inserted} = MemoryStore.ingest(store, attrs(tmp_dir))
    GenServer.stop(store)

    {:ok, restored} = MemoryStore.start_link(name: nil, path: path)
    on_exit(fn -> if Process.alive?(restored), do: GenServer.stop(restored) end)

    assert [%Observation{id: id}] = MemoryStore.list(restored)
    assert id == inserted.id

    assert {:ok, :duplicate, %Observation{id: ^id}} =
             MemoryStore.ingest(restored, attrs(tmp_dir))

    assert {:ok, stat} = File.stat(path)
    assert Bitwise.band(stat.mode, 0o077) == 0
  end

  test "unsupported schema fails closed until explicitly cleared", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "future.dat")
    File.write!(path, :erlang.term_to_binary(%{schema_version: 99}))
    {:ok, store} = MemoryStore.start_link(name: nil, path: path)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)

    assert MemoryStore.list(store) == []

    assert {:error, {:store_unavailable, {:unsupported_schema, 99}}} =
             MemoryStore.ingest(store, attrs(tmp_dir))

    assert :ok = MemoryStore.clear(store)
    assert {:ok, :inserted, _} = MemoryStore.ingest(store, attrs(tmp_dir))
  end

  test "corrupt persisted state fails closed without being overwritten", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "corrupt.dat")
    File.write!(path, "not an Erlang term")
    {:ok, store} = MemoryStore.start_link(name: nil, path: path)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)

    assert MemoryStore.list(store) == []

    assert {:error, {:store_unavailable, :unsafe_or_corrupt_term}} =
             MemoryStore.ingest(store, attrs(tmp_dir))

    assert File.read!(path) == "not an Erlang term"
  end

  test "invalid observations and persistence failures never mutate memory", %{tmp_dir: tmp_dir} do
    store = start_store(tmp_dir)

    assert {:error, :unresolved_project_scope} =
             MemoryStore.ingest(store, attrs(tmp_dir, %{project_scope: nil}))

    assert {:error, :invalid_observation} =
             MemoryStore.ingest(store, attrs(tmp_dir, %{kind: :unknown}))

    assert MemoryStore.count(store) == 0

    blocked = Path.join(tmp_dir, "blocked")
    File.write!(blocked, "not a directory")

    {:ok, failing_store} =
      MemoryStore.start_link(name: nil, path: Path.join(blocked, "memory.dat"))

    on_exit(fn -> if Process.alive?(failing_store), do: GenServer.stop(failing_store) end)

    assert {:error, {:persist_failed, _reason}} =
             MemoryStore.ingest(failing_store, attrs(tmp_dir))

    assert MemoryStore.count(failing_store) == 0
  end

  defp start_store(tmp_dir, opts \\ []) do
    name = :"memory_store_#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "#{name}.dat")
    start_supervised!({MemoryStore, Keyword.merge([name: name, path: path], opts)})
    name
  end
end
