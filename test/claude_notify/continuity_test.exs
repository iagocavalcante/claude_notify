defmodule ClaudeNotify.ContinuityTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.{Continuity, HandoffStore, MemoryPages, MemoryStore, StartupContext}
  alias ClaudeNotify.ProjectScope.Scope

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(Path.join(repo, "lib"))
    File.write!(Path.join(repo, "lib/example.ex"), "example")

    scope = %Scope{
      id: "project_continuity",
      name: "continuity",
      repo_root: repo,
      cwd: repo,
      worktree_root: repo,
      git_common_dir: Path.join(repo, ".git")
    }

    memory = :"continuity_memory_#{System.unique_integer([:positive])}"
    handoffs = :"continuity_handoffs_#{System.unique_integer([:positive])}"
    pages = :"continuity_pages_#{System.unique_integer([:positive])}"

    start_supervised!({MemoryStore, name: memory, path: Path.join(tmp_dir, "observations.dat")})
    start_supervised!({HandoffStore, name: handoffs, path: Path.join(tmp_dir, "handoffs.dat")})

    start_supervised!(
      {MemoryPages, name: pages, root: Path.join(tmp_dir, "pages"), handoff_store: handoffs}
    )

    %{scope: scope, memory: memory, handoffs: handoffs, pages: pages}
  end

  test "terminal stop checkpoints and session end finalizes one replay-safe episode", context do
    %{scope: scope, memory: memory, handoffs: handoffs, pages: pages} = context

    ingest(memory, scope, "prompt", :user_prompt, "Fix continuity. What remains?", 1)

    ingest(memory, scope, "tool", :tool_use, "", 2, %{
      "tool_family" => "edit",
      "files" => ["lib/example.ex"]
    })

    ingest(memory, scope, "stop", :turn_stop, "Implemented it. Next run the tests.", 3)

    opts = [memory_store: memory, handoff_store: handoffs, memory_pages: pages]
    session = %{id: "terminal-one", engine: "claude", project_scope: scope}

    assert %{handoff: {:ok, :inserted, first}, page: {:skipped, :turn_checkpoint}} =
             Continuity.terminal(session, :turn_stop, opts)

    assert first.summary =~ "Implemented"
    assert first.files_touched == ["lib/example.ex"]

    ingest(memory, scope, "end", :session_end, "", 4)

    assert %{handoff: {:ok, :inserted, final}, page: {:ok, :inserted, page}} =
             Continuity.terminal(session, :session_end, opts)

    assert HandoffStore.get(handoffs, first.id).state == :expired
    assert final.state == :open
    assert File.read!(page.path) =~ "Implemented it"

    assert %{handoff: {:ok, :duplicate, duplicate}, page: {:ok, :duplicate, duplicate_page}} =
             Continuity.terminal(session, :session_end, opts)

    assert duplicate.id == final.id
    assert duplicate_page.id == page.id
  end

  test "lifecycle-only sessions and launch-only dispatcher failures create nothing", context do
    %{scope: scope, memory: memory, handoffs: handoffs, pages: pages} = context
    opts = [memory_store: memory, handoff_store: handoffs, memory_pages: pages]

    ingest(memory, scope, "start", :session_start, "", 1)

    assert %{handoff: {:skipped, :no_meaningful_work}} =
             Continuity.terminal(
               %{id: "terminal-one", engine: "claude", project_scope: scope},
               :session_end,
               opts
             )

    ingest_dispatcher(memory, scope, 9, "prompt", :user_prompt, "Do it", 2)
    ingest_dispatcher(memory, scope, 9, "failed", :job_failed, "binary missing", 3)

    assert %{handoff: {:skipped, :no_meaningful_work}, page: {:skipped, :no_meaningful_work}} =
             Continuity.dispatcher(scope, %{id: 9, engine: "codex"}, opts)

    assert HandoffStore.list(handoffs) == []
  end

  test "dispatcher useful progress creates one portable handoff and Markdown page", context do
    %{scope: scope, memory: memory, handoffs: handoffs, pages: pages} = context
    opts = [memory_store: memory, handoff_store: handoffs, memory_pages: pages]

    ingest_dispatcher(memory, scope, 42, "prompt", :user_prompt, "Implement search", 1)
    ingest_dispatcher(memory, scope, 42, "text", :assistant_text, "Search is implemented.", 2)
    ingest_dispatcher(memory, scope, 42, "result", :result, "Done", 3)
    ingest_dispatcher(memory, scope, 42, "completed", :job_completed, "Done", 4)

    assert %{handoff: {:ok, :inserted, handoff}, page: {:ok, :inserted, page}} =
             Continuity.dispatcher(
               scope,
               %{id: 42, engine: "codex", engine_session_id: "thread-42"},
               opts
             )

    assert handoff.source == :dispatcher
    assert handoff.source_engine_session_id == "thread-42"
    assert page.job_id == 42
    assert File.read!(page.path) =~ "Dispatcher job #42 checkpoint"
  end

  test "startup context is cross-engine, bounded, untrusted, and claim-idempotent", context do
    %{scope: scope, handoffs: handoffs, pages: pages} = context

    {:ok, :inserted, source} =
      HandoffStore.upsert_automatic(handoffs, %{
        project_scope: scope,
        source: :terminal,
        source_engine: "claude",
        source_session_id: "claude-source",
        source_engine_session_id: "native-source",
        summary: String.duplicate("Portable work completed. ", 100),
        open_questions: ["What should Codex do next?"],
        next_steps: ["Continue safely."],
        files_touched: ["lib/example.ex"],
        generation: "one"
      })

    opts = [handoff_store: handoffs, memory_pages: pages, max_bytes: 1_024]

    assert {:ok, context_text} =
             StartupContext.for_scope(
               scope,
               %{session_id: "codex-receiver", engine: "codex"},
               opts
             )

    assert context_text =~ "UNTRUSTED HISTORICAL DATA"
    assert context_text =~ "Source: claude"
    refute context_text =~ "Current dispatcher"
    assert byte_size(context_text) <= 1_024
    assert String.valid?(context_text)

    assert {:ok, same_context} =
             StartupContext.for_scope(
               scope,
               %{session_id: "codex-receiver", engine: "codex"},
               opts
             )

    assert same_context == context_text
    assert HandoffStore.get(handoffs, source.id).accepted_by_session_id == "codex-receiver"

    {:ok, :inserted, _reverse_source} =
      HandoffStore.upsert_automatic(handoffs, %{
        project_scope: scope,
        source: :terminal,
        source_engine: "codex",
        source_session_id: "codex-source",
        summary: "Codex checkpoint for Claude.",
        generation: "reverse"
      })

    assert {:ok, reverse_context} =
             StartupContext.for_scope(
               scope,
               %{session_id: "claude-receiver", engine: "claude"},
               opts
             )

    assert reverse_context =~ "Source: codex"
    assert reverse_context =~ "Codex checkpoint for Claude"
  end

  test "native resume does not duplicate its own portable handoff", context do
    %{scope: scope, handoffs: handoffs, pages: pages} = context

    {:ok, :inserted, source} =
      HandoffStore.upsert_automatic(handoffs, %{
        project_scope: scope,
        source: :dispatcher,
        source_engine: "codex",
        source_session_id: "job:1",
        source_engine_session_id: "thread-1",
        summary: "Already present in native resume.",
        generation: "one"
      })

    assert {:ok, ""} =
             StartupContext.for_scope(
               scope,
               %{session_id: "job:2", engine: "codex", resume_session_id: "thread-1"},
               handoff_store: handoffs,
               memory_pages: pages
             )

    assert HandoffStore.get(handoffs, source.id).state == :open
  end

  defp ingest(store, scope, key, kind, body, sequence, metadata \\ %{}) do
    MemoryStore.ingest(store, %{
      ingest_key: key,
      project_scope: scope,
      source: :terminal,
      engine: "claude",
      session_id: "terminal-one",
      kind: kind,
      title: to_string(kind),
      body: body,
      metadata: metadata,
      sequence: sequence,
      created_at: 1_800_000_000_000 + sequence
    })
  end

  defp ingest_dispatcher(store, scope, job_id, key, kind, body, sequence) do
    MemoryStore.ingest(store, %{
      ingest_key: key,
      project_scope: scope,
      source: :dispatcher,
      engine: "codex",
      session_id: "thread-#{job_id}",
      job_id: job_id,
      kind: kind,
      title: to_string(kind),
      body: body,
      metadata: %{},
      sequence: sequence,
      created_at: 1_800_000_000_000 + sequence
    })
  end
end
