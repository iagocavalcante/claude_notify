defmodule ClaudeNotify.Engine.Fixture do
  @moduledoc """
  Test-only `ClaudeNotify.Engine` implementation: `build_command/2` points
  at a local script (given via `opts[:script]`) instead of the real `claude`
  binary, so `JobRunnerTest` and `JobSupervisorTest` can drive a real `Port`
  end to end without ever invoking the actual CLI. Event parsing is
  delegated to `ClaudeNotify.Engine.Claude` since the fixture script emits
  the same stream-json shape.
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
  defdelegate parse_event(line), to: ClaudeNotify.Engine.Claude
end

defmodule ClaudeNotify.Engine.SessionEventFixture do
  @moduledoc """
  Test-only `ClaudeNotify.Engine` implementation whose `parse_event/1`
  reports a session id via the dedicated `{:session, id}` event (a plain
  `"SESSION:<id>"` line) rather than folding it into a `:result` event, to
  prove `JobRunner` stores a session id reported either way. See
  `ClaudeNotify.Engine.Codex`, whose `thread.started` uses `:session` for
  the same reason: it reports identity before it knows the run's outcome.
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
  def parse_event("SESSION:" <> session_id), do: {:ok, {:session, session_id}}
  def parse_event(_line), do: :ignore
end

defmodule ClaudeNotify.JobRunnerTest do
  use ExUnit.Case, async: false

  alias ClaudeNotify.{
    Engine,
    HandoffStore,
    JobRunner,
    JobStore,
    JobSupervisor,
    JobTranscript,
    MemoryStore,
    ProjectRegistry,
    ProjectScope
  }

  @moduletag :tmp_dir

  # -- Fixtures --

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

  # A single fixture engine script drives every JobRunner/JobSupervisor
  # scenario below, branching on markers embedded in the (already
  # rule-wrapped) prompt it receives as $1:
  #
  #   * "FIXTURE_SLOW"    - sleeps before continuing, for concurrency-cap tests
  #   * "FIXTURE_CRASH"   - emits one line then exits non-zero
  #   * "FIXTURE_GARBAGE" - emits one line of invalid JSON before the rest
  #
  # It always records the prompt it received and its own cwd to files inside
  # that cwd, so tests can assert the prompt wrapper and the worktree cwd
  # wiring without any extra plumbing.
  defp write_fixture_engine(tmp_dir) do
    path = Path.join(tmp_dir, "fake_engine.sh")

    File.write!(path, """
    #!/usr/bin/env bash
    prompt="$1"
    echo "$prompt" > .received-prompt
    echo "$@" > .received-args
    pwd > .engine-cwd

    if [[ "$prompt" == *"FIXTURE_SLOW"* ]]; then
      sleep 0.5
    fi

    if [[ "$prompt" == *"FIXTURE_CRASH"* ]]; then
      echo '{"type":"system","subtype":"init","session_id":"fixture-session-crash"}'
      exit 7
    fi

    if [[ "$prompt" == *"FIXTURE_GARBAGE"* ]]; then
      echo 'not valid json at all'
    fi

    cat <<'JSON'
    {"type":"system","subtype":"init","cwd":"ignored","session_id":"fixture-session-1"}
    {"type":"assistant","message":{"content":[{"type":"text","text":"working on it"}]}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"echo hi"}}]}}
    {"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"fixture-session-1"}
    JSON
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp job_attrs(overrides \\ %{}) do
    Map.merge(
      %{engine: "claude", project: "fixture-project", prompt: "do the thing"},
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
    MemoryStore.clear()
    HandoffStore.clear()
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

  # -- Engine.Claude: pure unit tests, no process/port involved --

  describe "ClaudeNotify.Engine.Claude" do
    test "build_command/2 builds the claude CLI invocation" do
      assert {"claude", args} = Engine.Claude.build_command("do the thing", [])
      assert "-p" in args
      assert "do the thing" in args
      assert "--output-format" in args
      assert "stream-json" in args
      assert "--verbose" in args
      assert "--dangerously-skip-permissions" in args
      refute "--chrome" in args
    end

    test "build and resume commands enable Chrome when requested" do
      assert {"claude", build_args} = Engine.Claude.build_command("browse", chrome: true)
      assert "--chrome" in build_args

      assert {"claude", resume_args} =
               Engine.Claude.resume_command("sess-123", "continue", chrome: true)

      assert "--chrome" in resume_args
    end

    test "resume_command/3 includes --resume and the session id" do
      assert {"claude", args} = Engine.Claude.resume_command("sess-123", "continue", [])
      assert "--resume" in args
      assert "sess-123" in args
      assert "continue" in args
    end

    test "parse_event/1 parses the verified init/text/result lines" do
      assert {:ok, {:session, "abc"}} =
               Engine.Claude.parse_event(
                 ~s({"type":"system","subtype":"init","session_id":"abc"})
               )

      assert {:ok, {:text, "working on it"}} =
               Engine.Claude.parse_event(
                 ~s({"type":"assistant","message":{"content":[{"type":"text","text":"working on it"}]}})
               )

      assert {:ok, {:result, %{session_id: "abc", status: :ok, summary: "done"}}} =
               Engine.Claude.parse_event(
                 ~s({"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"abc"})
               )

      assert {:ok, {:result, %{status: :error}}} =
               Engine.Claude.parse_event(
                 ~s({"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom","session_id":"abc"})
               )
    end

    test "parse_event/1 parses a tool_use content block" do
      line =
        ~s({"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}})

      assert {:ok, {:tool_use, %{id: "t1", name: "Bash", input: %{"command" => "ls"}}}} =
               Engine.Claude.parse_event(line)
    end

    test "parse_event/1 ignores engine-internal noise" do
      assert :ignore =
               Engine.Claude.parse_event(~s({"type":"rate_limit_event","rate_limit_info":{}}))

      assert :ignore =
               Engine.Claude.parse_event(~s({"type":"system","subtype":"hook_started"}))
    end

    test "parse_event/1 returns an error, not a crash, for malformed JSON" do
      assert {:error, _reason} = Engine.Claude.parse_event("not json at all")
    end
  end

  describe "JobRunner.wrap_prompt/1" do
    test "prepends the job rules, including the no-push rule" do
      wrapped = JobRunner.wrap_prompt("do the thing")

      assert wrapped =~ "Never push"
      assert wrapped =~ "Stay inside this worktree"
      assert String.ends_with?(wrapped, "do the thing")
    end

    test "portable context follows job rules and precedes the current task" do
      wrapped = JobRunner.wrap_prompt("current task", "<historical>checkpoint</historical>")
      {rules_at, _} = :binary.match(wrapped, "Never push")
      {history_at, _} = :binary.match(wrapped, "<historical>")
      {task_at, _} = :binary.match(wrapped, "current task")
      assert rules_at < history_at
      assert history_at < task_at
    end
  end

  # -- JobRunner: real Port, real worktree, fixture engine script --

  describe "JobRunner" do
    defp start_runner(job, repo_path, script, overrides) do
      opts =
        Keyword.merge(
          [
            job_id: job.id,
            engine: Engine.Fixture,
            repo_path: repo_path,
            prompt: job.prompt,
            job_store: overrides[:job_store],
            slug: "run",
            engine_opts: [script: script]
          ],
          overrides
        )

      start_supervised!({JobRunner, opts})
    end

    test "runs a job end to end: worktree created, prompt wrapped, session id captured, completed",
         %{repo_path: repo_path, store: store, script: script} do
      {:ok, job} = JobStore.create(store, job_attrs())
      # JobRunner assumes the job is already :running - this is normally
      # done by JobSupervisor.Dispatcher as part of its concurrency-cap
      # decision (see job_supervisor_test scenarios below).
      {:ok, _} = JobStore.update_status(store, job.id, :running, %{})

      pid = start_runner(job, repo_path, script, job_store: store)

      final = wait_for_status(store, job.id, :completed)

      assert final.engine_session_id == "fixture-session-1"
      assert final.worktree_path
      assert File.dir?(final.worktree_path)
      assert final.branch == "job/#{job.id}-run"

      received_prompt = File.read!(Path.join(final.worktree_path, ".received-prompt"))
      assert received_prompt =~ "Never push"
      assert received_prompt =~ "do the thing"

      engine_cwd =
        final.worktree_path
        |> Path.join(".engine-cwd")
        |> File.read!()
        |> String.trim()

      assert Path.expand(engine_cwd) == Path.expand(final.worktree_path)

      refute Process.alive?(pid)
    end

    test "a fresh dispatcher job claims an eligible cross-engine terminal handoff", %{
      repo_path: repo_path,
      store: store,
      script: script
    } do
      registry = %ProjectRegistry{projects: %{"fixture-project" => repo_path}, aliases: %{}}
      {:ok, scope} = ProjectScope.for_project(registry, "fixture-project")

      {:ok, :inserted, handoff} =
        HandoffStore.upsert_automatic(%{
          project_scope: scope,
          source: :terminal,
          source_engine: "claude",
          source_session_id: "terminal-source",
          summary: "Carry this portable checkpoint into Codex.",
          generation: "stop:portable"
        })

      {:ok, job} = JobStore.create(store, job_attrs(%{engine: "codex"}))
      {:ok, _} = JobStore.update_status(store, job.id, :running, %{})

      start_runner(job, repo_path, script,
        job_store: store,
        project_scope: scope,
        engine_name: "codex"
      )

      final = wait_for_status(store, job.id, :completed)
      received = File.read!(Path.join(final.worktree_path, ".received-prompt"))
      assert received =~ "UNTRUSTED HISTORICAL DATA"
      assert received =~ "Carry this portable checkpoint into Codex"
      assert received =~ "do the thing"
      assert HandoffStore.get(handoff.id).accepted_by_job_id == job.id
    end

    test "a nonzero engine exit marks the job failed, cleanly", %{
      repo_path: repo_path,
      store: store,
      script: script
    } do
      {:ok, job} = JobStore.create(store, job_attrs(%{prompt: "FIXTURE_CRASH do the thing"}))
      {:ok, _} = JobStore.update_status(store, job.id, :running, %{})

      start_runner(job, repo_path, script, job_store: store)

      final = wait_for_status(store, job.id, :failed)
      assert final.status == :failed
      assert final.engine_session_id == "fixture-session-crash"
    end

    test "a malformed stream-json line is skipped, not fatal", %{
      repo_path: repo_path,
      store: store,
      script: script
    } do
      {:ok, job} = JobStore.create(store, job_attrs(%{prompt: "FIXTURE_GARBAGE do the thing"}))
      {:ok, _} = JobStore.update_status(store, job.id, :running, %{})

      start_runner(job, repo_path, script, job_store: store)

      final = wait_for_status(store, job.id, :completed)
      assert final.engine_session_id == "fixture-session-1"
    end

    test "an unresolvable project path fails the job instead of crashing", %{
      store: store,
      script: script
    } do
      {:ok, job} = JobStore.create(store, job_attrs())
      {:ok, _} = JobStore.update_status(store, job.id, :running, %{})

      start_runner(job, "/nonexistent/path/for/sure", script, job_store: store)

      final = wait_for_status(store, job.id, :failed)
      assert final.status == :failed
    end

    test "a {:session, id} event (not carried by a :result) stores the session id too", %{
      repo_path: repo_path,
      store: store,
      tmp_dir: tmp_dir
    } do
      script = Path.join(tmp_dir, "session_event_fixture.sh")

      File.write!(script, """
      #!/usr/bin/env bash
      echo "SESSION:session-event-fixture-1"
      echo "some other line the fixture engine ignores"
      exit 0
      """)

      File.chmod!(script, 0o755)

      {:ok, job} = JobStore.create(store, job_attrs())
      {:ok, _} = JobStore.update_status(store, job.id, :running, %{})

      start_runner(job, repo_path, script, job_store: store, engine: Engine.SessionEventFixture)

      final = wait_for_status(store, job.id, :completed)
      assert final.engine_session_id == "session-event-fixture-1"
    end

    test "job_id/1 exposes the job id this runner is driving", %{
      repo_path: repo_path,
      store: store,
      script: script
    } do
      {:ok, job} = JobStore.create(store, job_attrs())
      {:ok, _} = JobStore.update_status(store, job.id, :running, %{})

      pid = start_runner(job, repo_path, script, job_store: store)

      assert JobRunner.job_id(pid) == job.id

      wait_for_status(store, job.id, :completed)
    end

    test "opts[:resume_session_id] makes the engine's resume_command run instead of build_command",
         %{repo_path: repo_path, store: store, script: script} do
      {:ok, job} = JobStore.create(store, job_attrs(%{prompt: "continue the work"}))
      {:ok, _} = JobStore.update_status(store, job.id, :running, %{})

      start_runner(job, repo_path, script,
        job_store: store,
        resume_session_id: "fixture-original-session"
      )

      final = wait_for_status(store, job.id, :completed)

      args = final.worktree_path |> Path.join(".received-args") |> File.read!() |> String.trim()
      assert String.starts_with?(args, "--resume fixture-original-session")
      assert args =~ "continue the work"
    end

    test "feeds a fixture run's text/tool_use events into ClaudeNotify.JobTranscript, and hands the completion notifier a snapshot",
         %{repo_path: repo_path, store: store, script: script} do
      transcript_name = :"job_transcript_#{System.unique_integer([:positive])}"
      transcript = start_supervised!({JobTranscript, name: transcript_name})

      {:ok, job} = JobStore.create(store, job_attrs())
      {:ok, _} = JobStore.update_status(store, job.id, :running, %{})

      test_pid = self()
      notifier = fn event -> send(test_pid, event) end

      start_runner(job, repo_path, script,
        job_store: store,
        job_transcript: transcript,
        notifier: notifier
      )

      wait_for_status(store, job.id, :completed)

      assert_receive {:completed, job_id, %{transcript: entries}}, 2_000
      assert job_id == job.id

      # Fixture engine (write_fixture_engine/1) emits one :text then one
      # :tool_use (a Bash call with no file_path) before its :result.
      assert [
               %{type: :text, text: "working on it"},
               %{type: :tool_use, name: "Bash", file_path: nil, diff: nil}
             ] = entries

      # Discarded right after the notifier received its snapshot - see
      # ClaudeNotify.JobTranscript's moduledoc cleanup policy.
      assert JobTranscript.transcript(transcript, job.id) == []
    end

    test "a file-editing tool_use is enriched with a git diff for that file in the job's worktree",
         %{repo_path: repo_path, store: store, tmp_dir: tmp_dir} do
      script = Path.join(tmp_dir, "diff_fixture_engine.sh")

      File.write!(script, """
      #!/usr/bin/env bash
      echo "extra line" >> README.md
      cat <<'JSON'
      {"type":"system","subtype":"init","cwd":"ignored","session_id":"fixture-session-diff"}
      {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Edit","input":{"file_path":"README.md"}}]}}
      {"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"fixture-session-diff"}
      JSON
      exit 0
      """)

      File.chmod!(script, 0o755)

      transcript_name = :"job_transcript_#{System.unique_integer([:positive])}"
      transcript = start_supervised!({JobTranscript, name: transcript_name})

      {:ok, job} = JobStore.create(store, job_attrs())
      {:ok, _} = JobStore.update_status(store, job.id, :running, %{})

      test_pid = self()
      notifier = fn event -> send(test_pid, event) end

      start_runner(job, repo_path, script,
        job_store: store,
        job_transcript: transcript,
        notifier: notifier
      )

      wait_for_status(store, job.id, :completed)

      assert_receive {:completed, _job_id,
                      %{
                        transcript: [
                          %{type: :tool_use, name: "Edit", file_path: "README.md", diff: diff}
                        ]
                      }},
                     2_000

      assert diff =~ "extra line"
    end
  end

  # -- JobSupervisor: concurrency cap, queueing, crash isolation --

  describe "JobSupervisor" do
    setup %{repo_path: repo_path} do
      dyn_name = :"job_dyn_sup_#{System.unique_integer([:positive])}"
      dispatcher_name = :"job_dispatcher_#{System.unique_integer([:positive])}"

      start_supervised!(%{
        id: dyn_name,
        start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: dyn_name]]}
      })

      start_supervised!(
        {JobSupervisor.Dispatcher, name: dispatcher_name, dynamic_supervisor: dyn_name, cap: 3}
      )

      registry = %ProjectRegistry{projects: %{"fixture-project" => repo_path}, aliases: %{}}

      %{dispatcher: dispatcher_name, dyn_sup: dyn_name, registry: registry}
    end

    defp common_opts(store, script, registry, dispatcher) do
      [
        job_store: store,
        engine_module: Engine.Fixture,
        engine_opts: [script: script],
        project_registry: registry,
        dispatcher: dispatcher
      ]
    end

    test "captures an ordered, sanitized dispatcher lifecycle", %{
      store: store,
      script: script,
      dispatcher: dispatcher,
      registry: registry
    } do
      {:ok, job} = JobStore.create(store, job_attrs())

      assert :started =
               JobSupervisor.start_job(
                 job,
                 common_opts(store, script, registry, dispatcher)
               )

      wait_for_status(store, job.id, :completed)

      observations = MemoryStore.list(job_id: job.id)

      assert Enum.map(observations, & &1.kind) == [
               :user_prompt,
               :session_start,
               :assistant_text,
               :tool_use,
               :result,
               :job_completed
             ]

      assert Enum.map(observations, & &1.sequence) == Enum.to_list(1..6)
      assert Enum.uniq(Enum.map(observations, & &1.project_id)) |> length() == 1

      tool = Enum.find(observations, &(&1.kind == :tool_use))
      assert tool.body == ""
      assert tool.metadata["tool_family"] == "shell"
      refute inspect(tool) =~ "echo hi"
    end

    test "a 4th concurrent job queues until a slot frees (cap 3)", %{
      store: store,
      script: script,
      dispatcher: dispatcher,
      registry: registry
    } do
      jobs =
        for _ <- 1..4 do
          {:ok, job} = JobStore.create(store, job_attrs(%{prompt: "FIXTURE_SLOW do the thing"}))
          job
        end

      opts = common_opts(store, script, registry, dispatcher)
      results = Enum.map(jobs, &JobSupervisor.start_job(&1, opts))

      assert Enum.count(results, &(&1 == :started)) == 3
      assert Enum.count(results, &(&1 == :queued)) == 1

      assert JobSupervisor.Dispatcher.running_count(dispatcher) == 3
      assert JobSupervisor.Dispatcher.queue_length(dispatcher) == 1

      Enum.each(jobs, fn job -> wait_for_status(store, job.id, :completed) end)

      assert JobSupervisor.Dispatcher.queue_length(dispatcher) == 0
      assert JobSupervisor.Dispatcher.running_count(dispatcher) == 0
    end

    test "a crashing job's runner fails only that job - supervisor and siblings survive", %{
      store: store,
      script: script,
      dispatcher: dispatcher,
      registry: registry
    } do
      {:ok, crash_job} =
        JobStore.create(store, job_attrs(%{prompt: "FIXTURE_CRASH do the thing"}))

      {:ok, ok_job} = JobStore.create(store, job_attrs(%{prompt: "do the thing"}))

      opts = common_opts(store, script, registry, dispatcher)

      assert :started = JobSupervisor.start_job(crash_job, opts)
      assert :started = JobSupervisor.start_job(ok_job, opts)

      wait_for_status(store, crash_job.id, :failed)
      wait_for_status(store, ok_job.id, :completed)

      assert Process.alive?(Process.whereis(dispatcher))
    end

    test "stop_job/2 terminates a running job's runner process", %{
      store: store,
      script: script,
      dispatcher: dispatcher,
      dyn_sup: dyn_sup,
      registry: registry
    } do
      {:ok, job} = JobStore.create(store, job_attrs(%{prompt: "FIXTURE_SLOW do the thing"}))
      opts = common_opts(store, script, registry, dispatcher)

      assert :started = JobSupervisor.start_job(job, opts)
      assert [{_, pid, :worker, _}] = DynamicSupervisor.which_children(dyn_sup)

      assert :stopped = JobSupervisor.stop_job(job.id, dynamic_supervisor: dyn_sup)

      refute Process.alive?(pid)
      assert DynamicSupervisor.which_children(dyn_sup) == []
    end

    test "stop_job/2 returns :not_found when no runner is running for that job id", %{
      dyn_sup: dyn_sup
    } do
      assert :not_found = JobSupervisor.stop_job(999_999, dynamic_supervisor: dyn_sup)
    end
  end
end
