defmodule ClaudeNotify.Engine.CodexFixture do
  @moduledoc """
  Test-only `ClaudeNotify.Engine` implementation: `build_command/2` points at
  a local script (given via `opts[:script]`) instead of the real `codex`
  binary, so `CodexTest` can drive a real `Port` end to end without ever
  invoking the actual CLI. Event parsing is delegated to
  `ClaudeNotify.Engine.Codex` since the fixture script emits the same
  `--experimental-json` shape. Mirrors `ClaudeNotify.Engine.Fixture` (see
  `job_runner_test.exs`), which does the same thing for Claude.
  """

  @behaviour ClaudeNotify.Engine

  @impl true
  def build_command(prompt, opts) do
    script = Keyword.fetch!(opts, :script)
    {script, [prompt]}
  end

  @impl true
  def resume_command(session_id, prompt, opts) do
    {cmd, args} = build_command(prompt, opts)
    {cmd, ["--resume", session_id | args]}
  end

  @impl true
  defdelegate parse_event(line), to: ClaudeNotify.Engine.Codex
end

defmodule ClaudeNotify.Engine.CodexMissingFixture do
  @moduledoc """
  Test-only `ClaudeNotify.Engine` implementation shaped exactly like the
  real `ClaudeNotify.Engine.Codex` (`build_command/2` hardcodes an
  executable name, ignoring `opts`), except the executable name is
  guaranteed not to exist on any `PATH`. Used to exercise
  `JobRunner`'s "missing executable" failure path for a codex-shaped
  command without mutating the real `PATH` env var (which would risk
  starving concurrently-running async tests of `git`/`bash`).
  """

  @behaviour ClaudeNotify.Engine

  @impl true
  def build_command(prompt, _opts) do
    {"definitely-not-a-real-codex-binary-claude-notify-233", ["exec", prompt]}
  end

  @impl true
  def resume_command(session_id, prompt, _opts) do
    {cmd, args} = build_command(prompt, [])
    {cmd, ["resume", session_id | args]}
  end

  @impl true
  defdelegate parse_event(line), to: ClaudeNotify.Engine.Codex
end

defmodule ClaudeNotify.Engine.CodexTest do
  use ExUnit.Case, async: false

  alias ClaudeNotify.{Engine, JobRunner, JobStore}

  @moduletag :tmp_dir

  # -- Engine.Codex: pure unit tests, no process/port involved --

  describe "build_command/2" do
    test "builds the codex exec invocation, sandboxed and headless" do
      assert {"codex", args} = Engine.Codex.build_command("do the thing", [])
      assert "exec" in args
      assert "--experimental-json" in args
      assert "--sandbox" in args
      assert "workspace-write" in args
      assert "--ask-for-approval" in args
      assert "never" in args
      assert "do the thing" in args
    end

    test "does not pass a -C/--cd flag - the worktree cwd comes from the Port, not argv" do
      {"codex", args} = Engine.Codex.build_command("do the thing", [])
      refute "-C" in args
      refute "--cd" in args
    end
  end

  describe "resume_command/3" do
    test "issues codex exec resume with the stored session id, no sandbox/approval flags" do
      assert {"codex", args} = Engine.Codex.resume_command("thread-abc-123", "continue", [])
      assert args == ["exec", "resume", "thread-abc-123", "--experimental-json", "continue"]

      # resume does not accept these (confirmed via `codex exec resume --help`
      # and a clap "unexpected argument" probe - see the moduledoc)
      refute "--sandbox" in args
      refute "--ask-for-approval" in args
    end
  end

  describe "parse_event/1" do
    test "thread.started becomes a :session event carrying the thread id" do
      assert {:ok, {:session, "thread-xyz"}} =
               Engine.Codex.parse_event(~s({"type":"thread.started","thread_id":"thread-xyz"}))
    end

    test "item.completed with an agent_message item becomes :text" do
      line =
        ~s({"type":"item.completed","item":{"type":"agent_message","text":"working on it"}})

      assert {:ok, {:text, "working on it"}} = Engine.Codex.parse_event(line)
    end

    test "item.completed with a non-agent_message item becomes :tool_use" do
      line =
        ~s({"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"echo hi"}})

      assert {:ok, {:tool_use, %{id: "item_1", name: "command_execution", input: input}}} =
               Engine.Codex.parse_event(line)

      assert input["command"] == "echo hi"
    end

    test "turn.completed becomes a terminal :ok :result event" do
      assert {:ok, {:result, %{session_id: nil, status: :ok, summary: nil}}} =
               Engine.Codex.parse_event(~s({"type":"turn.completed","usage":{"input_tokens":1}}))
    end

    test "turn.failed becomes a terminal :error :result event carrying the error message" do
      line = ~s({"type":"turn.failed","error":{"message":"boom"}})

      assert {:ok, {:result, %{session_id: nil, status: :error, summary: "boom"}}} =
               Engine.Codex.parse_event(line)
    end

    test "ignores engine-internal event types" do
      assert :ignore = Engine.Codex.parse_event(~s({"type":"item.started","item":{}}))
      assert :ignore = Engine.Codex.parse_event(~s({"type":"turn.started"}))
    end

    test "returns an error, not a crash, for malformed JSON" do
      assert {:error, _reason} = Engine.Codex.parse_event("not json at all")
    end
  end

  # -- JobRunner: real Port, real worktree, fixture engine script --

  defp create_fixture_repo(tmp_dir) do
    path = Path.join(tmp_dir, "repo")
    File.mkdir_p!(path)

    {_, 0} = System.cmd("git", ["init", "-q"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: path)
    File.write!(Path.join(path, "README.md"), "fixture\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: path)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "initial commit"], cd: path)

    path
  end

  # Emits the `--experimental-json` shape modeled in `Engine.Codex`'s
  # moduledoc: a `thread.started` id, one `agent_message` item, one
  # non-agent_message item (proving the generic :tool_use fallback), then a
  # successful `turn.completed`.
  defp write_fixture_engine(tmp_dir) do
    path = Path.join(tmp_dir, "fake_codex.sh")

    File.write!(path, """
    #!/usr/bin/env bash
    prompt="$1"
    echo "$prompt" > .received-prompt
    pwd > .engine-cwd

    cat <<'JSON'
    {"type":"thread.started","thread_id":"codex-fixture-thread-1"}
    {"type":"item.completed","item":{"type":"agent_message","text":"working on it"}}
    {"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"echo hi"}}
    {"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}
    JSON
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp job_attrs(overrides \\ %{}) do
    Map.merge(
      %{engine: "codex", project: "fixture-project", prompt: "do the thing"},
      overrides
    )
  end

  defp wait_for_status(store, job_id, status, attempts \\ 150) do
    job = JobStore.get(store, job_id)

    cond do
      job && job.status == status ->
        job

      attempts <= 0 ->
        flunk("job #{job_id} never reached status #{inspect(status)}, last seen: #{inspect(job)}")

      true ->
        Process.sleep(20)
        wait_for_status(store, job_id, status, attempts - 1)
    end
  end

  setup %{tmp_dir: tmp_dir} do
    repo_path = create_fixture_repo(tmp_dir)
    base_dir = Path.join(tmp_dir, "worktrees_base")
    previous_base_dir = Application.get_env(:claude_notify, :worktree_base_dir)
    Application.put_env(:claude_notify, :worktree_base_dir, base_dir)

    on_exit(fn ->
      case previous_base_dir do
        nil -> Application.delete_env(:claude_notify, :worktree_base_dir)
        value -> Application.put_env(:claude_notify, :worktree_base_dir, value)
      end
    end)

    store = :"job_store_#{System.unique_integer([:positive])}"
    start_supervised!({JobStore, name: store, path: Path.join(tmp_dir, "jobs.dat")})

    script = write_fixture_engine(tmp_dir)

    %{repo_path: repo_path, store: store, script: script}
  end

  defp start_runner(job, repo_path, engine, overrides) do
    opts =
      Keyword.merge(
        [
          job_id: job.id,
          engine: engine,
          repo_path: repo_path,
          prompt: job.prompt,
          job_store: overrides[:job_store],
          slug: "run"
        ],
        overrides
      )

    start_supervised!({JobRunner, opts})
  end

  test "a codex job runs end to end: worktree created, cwd confined, session id captured, completed",
       %{repo_path: repo_path, store: store, script: script} do
    {:ok, job} = JobStore.create(store, job_attrs())
    {:ok, _} = JobStore.update_status(store, job.id, :running, %{})

    start_runner(job, repo_path, Engine.CodexFixture,
      job_store: store,
      engine_opts: [script: script]
    )

    final = wait_for_status(store, job.id, :completed)

    assert final.engine_session_id == "codex-fixture-thread-1"
    assert final.worktree_path
    assert File.dir?(final.worktree_path)

    engine_cwd =
      final.worktree_path
      |> Path.join(".engine-cwd")
      |> File.read!()
      |> String.trim()

    assert Path.expand(engine_cwd) == Path.expand(final.worktree_path)
  end

  test "a codex binary missing from PATH fails the job with a clear error, not a crash", %{
    repo_path: repo_path,
    store: store
  } do
    {:ok, job} = JobStore.create(store, job_attrs())
    {:ok, _} = JobStore.update_status(store, job.id, :running, %{})

    start_runner(job, repo_path, Engine.CodexMissingFixture, job_store: store)

    final = wait_for_status(store, job.id, :failed)
    assert final.status == :failed
  end
end
