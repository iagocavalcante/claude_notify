defmodule ClaudeNotify.MemoryPagesTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.{HandoffStore, MemoryPages}
  alias ClaudeNotify.MemoryPages.Page
  alias ClaudeNotify.ProjectScope.Scope

  @moduletag :tmp_dir

  defp scope(tmp_dir, id \\ "project_one") do
    root = Path.join(tmp_dir, "repos/#{id}")
    File.mkdir_p!(root)

    %Scope{
      id: id,
      name: id,
      repo_root: root,
      cwd: root,
      worktree_root: root,
      git_common_dir: Path.join(root, ".git")
    }
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        completion_key: "session-end:one",
        source: :terminal,
        engine: "claude",
        session_id: "session-one",
        summary: "Implemented café-safe lexical retrieval.",
        decisions: ["Decided to keep Markdown authoritative."],
        failed_approaches: ["A transient in-memory index failed after restart."],
        open_questions: ["Should rules be pinned?"],
        next_steps: ["Rebuild the SQLite index."],
        files_touched: ["lib/memory_pages.ex"],
        created_at: 1_800_000_000_000
      },
      overrides
    )
  end

  test "writes readable atomic Markdown and deduplicates completion replay", %{tmp_dir: tmp_dir} do
    {store, _root} = start_pages(tmp_dir)
    project = scope(tmp_dir)

    assert {:ok, :inserted, %Page{} = page} =
             MemoryPages.write_episode(store, project, attrs())

    assert File.regular?(page.path)
    content = File.read!(page.path)
    assert content =~ "# Terminal session checkpoint"
    assert content =~ "## Summary"
    assert content =~ "Markdown authoritative"
    refute File.exists?(page.path <> ".tmp")

    assert {:ok, stat} = File.stat(page.path)
    assert Bitwise.band(stat.mode, 0o077) == 0

    assert {:ok, :duplicate, %Page{id: same_id}} =
             MemoryPages.write_episode(store, project, attrs(%{summary: "replayed body"}))

    assert same_id == page.id
    assert File.read!(page.path) == content
    assert {:ok, %Page{id: read_id}} = MemoryPages.read(store, project.id, page.id)
    assert read_id == page.id
  end

  test "FTS search is Unicode-aware and never crosses project boundaries", %{tmp_dir: tmp_dir} do
    {store, _root} = start_pages(tmp_dir)
    first = scope(tmp_dir, "project_one")
    second = scope(tmp_dir, "project_two")

    {:ok, :inserted, first_page} = MemoryPages.write_episode(store, first, attrs())

    {:ok, :inserted, _second_page} =
      MemoryPages.write_episode(
        store,
        second,
        attrs(%{
          completion_key: "two",
          session_id: "session-two",
          summary: "Another café mentions lexical retrieval."
        })
      )

    assert {:ok, [%{page_id: id, project_id: "project_one", snippet: snippet}]} =
             MemoryPages.search(store, first.id, "café lexical")

    assert id == first_page.id
    assert snippet =~ "café"

    assert {:ok, [%{project_id: "project_two"}]} =
             MemoryPages.search(store, second.id, "café lexical")

    assert {:ok, [%{page_id: recent_id}]} = MemoryPages.recent(store, first.id)
    assert recent_id == first_page.id
  end

  test "the derived index can be deleted and rebuilt entirely from Markdown", %{tmp_dir: tmp_dir} do
    {store, root} = start_pages(tmp_dir)
    project = scope(tmp_dir)
    {:ok, :inserted, page} = MemoryPages.write_episode(store, project, attrs())
    GenServer.stop(store)

    File.rm!(Path.join(root, "memory-index.sqlite3"))
    restored_name = :"memory_pages_restored_#{System.unique_integer([:positive])}"

    {:ok, restored} =
      MemoryPages.start_link(name: restored_name, root: root, handoff_store: nil)

    on_exit(fn -> if Process.alive?(restored), do: GenServer.stop(restored) end)
    assert {:ok, []} = MemoryPages.recent(restored, project.id)
    assert {:ok, %{indexed: 1, corrupt: []}} = MemoryPages.reindex(restored)

    assert {:ok, [%{page_id: id}]} = MemoryPages.search(restored, project.id, "authoritative")
    assert id == page.id
  end

  test "corrupt Markdown is reported without crashing status or reindex", %{tmp_dir: tmp_dir} do
    {store, root} = start_pages(tmp_dir)
    project = scope(tmp_dir)
    {:ok, :inserted, _page} = MemoryPages.write_episode(store, project, attrs())

    corrupt = Path.join([root, "projects", project.id, "episodes", "corrupt.md"])
    File.write!(corrupt, "not a memory page")
    File.write!(Path.join([root, "projects", project.id, "rules.md"]), "# Trusted project rules")

    {:ok, index_connection} =
      Exqlite.Sqlite3.open(Path.join(root, "memory-index.sqlite3"))

    :ok =
      Exqlite.Sqlite3.execute(
        index_connection,
        """
        INSERT INTO memory_fts
          (page_id, project_id, created_at, source, engine, session_id, path, title, body)
        VALUES
          ('bad_index_row', 'project_one', 1800000000001, 'terminal', 'claude',
           'bad-session', '/outside/missing.md', 'Bad row', 'stale index data')
        """
      )

    :ok = Exqlite.Sqlite3.close(index_connection)

    assert {:ok, status} = MemoryPages.status(store, project.id)
    assert length(status.corrupt_pages) == 1
    assert length(status.corrupt_index_rows) == 1
    refute status.healthy?

    assert {:ok, %{indexed: 1, corrupt: [%{path: ^corrupt}]}} = MemoryPages.reindex(store)
    assert Process.alive?(Process.whereis(store))
  end

  test "page paths and briefing sizes are bounded", %{tmp_dir: tmp_dir} do
    handoffs = :"memory_page_handoffs_#{System.unique_integer([:positive])}"
    start_supervised!({HandoffStore, name: handoffs, path: nil})
    {store, root} = start_pages(tmp_dir, handoff_store: handoffs, max_briefing_bytes: 512)
    project = scope(tmp_dir)

    assert {:error, :invalid_page} =
             MemoryPages.write_episode(store, %{project | id: "../../escape"}, attrs())

    symlink_scope = scope(tmp_dir, "project_symlink")
    outside = Path.join(tmp_dir, "outside-memory-root")
    File.mkdir_p!(outside)
    project_memory_dir = Path.join([root, "projects", symlink_scope.id])
    File.mkdir_p!(project_memory_dir)
    File.ln_s!(outside, Path.join(project_memory_dir, "episodes"))

    assert {:error, :unsafe_page_path} =
             MemoryPages.write_episode(
               store,
               symlink_scope,
               attrs(%{completion_key: "symlink-escape"})
             )

    {:ok, :inserted, _page} =
      MemoryPages.write_episode(
        store,
        project,
        attrs(%{summary: String.duplicate("bounded memory ", 200)})
      )

    assert {:ok, briefing} = MemoryPages.briefing(store, project.id)
    assert byte_size(briefing) <= 512
    refute File.exists?(Path.join(tmp_dir, "escape"))
    assert String.starts_with?(Path.expand(root), Path.expand(tmp_dir))
  end

  defp start_pages(tmp_dir, opts \\ []) do
    name = :"memory_pages_#{System.unique_integer([:positive])}"
    root = Path.join(tmp_dir, to_string(name))
    start_supervised!({MemoryPages, Keyword.merge([name: name, root: root], opts)})
    {name, root}
  end
end
