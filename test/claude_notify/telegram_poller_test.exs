defmodule ClaudeNotify.TelegramPollerTest do
  use ExUnit.Case, async: false

  alias ClaudeNotify.{
    TelegramPoller,
    SessionStore,
    JobStore,
    JobSupervisor,
    JobTranscript,
    ProjectRegistry
  }

  @moduletag :tmp_dir

  # Records sent Telegram texts to the test process instead of hitting the
  # network - same rationale/shape as JobReconcilerTest's FakeTelegram.
  #
  # The job progress/completion notifier (ClaudeNotify.JobRunner's
  # `opts[:notifier]`) runs INSIDE the JobRunner process, not the test
  # process - `self()` there is the runner's own pid, not the test's. So
  # unlike a plain `send(self(), ...)`, every function here forwards through
  # the name registered below (see the "job commands" describe block's
  # setup), which is always the actual test process regardless of which
  # process called in.
  defmodule FakeTelegram do
    def send_message(text) do
      forward({:telegram_send, text})
      {:ok, %{"result" => %{"message_id" => System.unique_integer([:positive, :monotonic])}}}
    end

    # Forwards as the SAME {:telegram_send, text} tuple as send_message/1
    # above (buttons intentionally not part of the observable tuple, same
    # observability level send_message/1 itself has) - this keeps every
    # pre-existing `assert_receive {:telegram_send, text}` valid unchanged
    # now that the job activity message's initial send carries a [Watch]
    # button (see ClaudeNotify.TelegramPoller.send_and_track_activity_message/3).
    # Watch-mode tests prove the button works functionally (tapping
    # "jobwatch:<id>" starts a watch), the same way every other job button
    # (Show diff/Create PR/...) is already proven here - not by inspecting
    # this call's button list.
    def send_with_buttons(text, _buttons) do
      forward({:telegram_send, text})
      {:ok, %{"result" => %{"message_id" => System.unique_integer([:positive, :monotonic])}}}
    end

    def edit_message_text(message_id, text) do
      forward({:telegram_edit, message_id, text})
      {:ok, %{"result" => %{"message_id" => message_id}}}
    end

    def edit_message_text_with_buttons(message_id, text, buttons) do
      forward({:telegram_edit_buttons, message_id, text, buttons})
      {:ok, %{"result" => %{"message_id" => message_id}}}
    end

    def edit_message_reply_markup(message_id, buttons) do
      forward({:telegram_edit_markup, message_id, buttons})
      {:ok, %{"result" => %{"message_id" => message_id}}}
    end

    defp forward(message) do
      case Process.whereis(:telegram_poller_test_process) do
        nil -> send(self(), message)
        pid -> send(pid, message)
      end
    end
  end

  # Test-only ClaudeNotify.Engine implementation, deliberately NOT shared
  # with JobRunnerTest's own `ClaudeNotify.Engine.Fixture` - `mix test
  # test/claude_notify/telegram_poller_test.exs` (this story's specified
  # test command) only compiles this one file, so this file needs to be
  # runnable standalone. See ClaudeNotify.Engine.Fixture's own moduledoc for
  # the identical rationale.
  defmodule FixtureEngine do
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

  setup do
    original = Application.get_env(:claude_notify, :telegram_chat_id)

    on_exit(fn ->
      Application.put_env(:claude_notify, :telegram_chat_id, original)
    end)

    :ok
  end

  test "authorized_chat?/1 accepts only configured chat id" do
    Application.put_env(:claude_notify, :telegram_chat_id, "123456")

    assert TelegramPoller.authorized_chat?(123_456)
    assert TelegramPoller.authorized_chat?("123456")
    refute TelegramPoller.authorized_chat?("999999")
  end

  test "reply to a tracked message looks up correct session" do
    SessionStore.register_prompt("sess-1", "hello", "/tmp/test", %{"tty_path" => "/dev/ttys001"})
    SessionStore.register_message(42, "sess-1")

    # Verify the message-to-session lookup works
    assert SessionStore.lookup_session_by_message(42) == "sess-1"

    # Verify the session has the expected tty_path
    session = SessionStore.get_session("sess-1")
    assert session[:tty_path] == "/dev/ttys001"
  end

  describe "job commands" do
    @chat_id 123_456

    setup %{tmp_dir: tmp_dir} do
      Application.put_env(:claude_notify, :telegram_chat_id, @chat_id)

      # See FakeTelegram's moduledoc-adjacent comment above: the job
      # progress/completion notifier runs inside the JobRunner process, so
      # FakeTelegram forwards through this registered name instead of
      # `send(self(), ...)` to reach the test process regardless of caller.
      # The name dies with this test process (ExUnit runs each test in its
      # own process), so no explicit unregister is needed between tests.
      if Process.whereis(:telegram_poller_test_process) do
        Process.unregister(:telegram_poller_test_process)
      end

      Process.register(self(), :telegram_poller_test_process)

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

      dyn_sup = :"job_dyn_sup_#{System.unique_integer([:positive])}"
      dispatcher = :"job_dispatcher_#{System.unique_integer([:positive])}"

      start_supervised!(%{
        id: dyn_sup,
        start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: dyn_sup]]}
      })

      start_supervised!(
        {JobSupervisor.Dispatcher, name: dispatcher, dynamic_supervisor: dyn_sup, cap: 3}
      )

      registry = %ProjectRegistry{projects: %{"trainer" => repo_path}, aliases: %{}}
      script = write_fixture_engine(tmp_dir)

      job_launch_opts = [
        dispatcher: dispatcher,
        dynamic_supervisor: dyn_sup,
        engine_module: FixtureEngine,
        engine_opts: [script: script]
      ]

      # A per-test isolated ClaudeNotify.JobTranscript, same rationale as
      # `store` above - keeps each test's transcript entries independent of
      # the app's global singleton and every other test.
      transcript = :"job_transcript_#{System.unique_integer([:positive])}"
      start_supervised!({JobTranscript, name: transcript})

      state = %{
        offset: 0,
        selected_sessions: %{},
        telegram: FakeTelegram,
        job_store: store,
        job_transcript: transcript,
        project_registry: registry,
        job_launch_opts: job_launch_opts,
        cmd_runner: fake_cmd_runner(),
        watches: %{}
      }

      %{store: store, registry: registry, transcript: transcript, state: state}
    end

    # -- Fixtures / helpers --

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

    # Mirrors JobRunnerTest's shared fixture engine script exactly (same
    # markers, same recorded files) - see its moduledoc-adjacent comment
    # there for the marker list.
    defp write_fixture_engine(tmp_dir) do
      path = Path.join(tmp_dir, "fake_engine.sh")

      File.write!(path, """
      #!/usr/bin/env bash
      prompt="$1"
      echo "$prompt" > .received-prompt
      pwd > .engine-cwd

      if [[ "$prompt" == *"FIXTURE_SLOW"* ]]; then
        sleep 0.5
      fi

      cat <<'JSON'
      {"type":"system","subtype":"init","cwd":"ignored","session_id":"fixture-session-1"}
      {"type":"assistant","message":{"content":[{"type":"text","text":"working on it"}]}}
      {"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"fixture-session-1"}
      JSON
      exit 0
      """)

      File.chmod!(path, 0o755)
      path
    end

    # Same shape as write_fixture_engine/1, plus a Read tool_use event before
    # the result - for tests proving the progress/completion notifier hook.
    defp write_fixture_engine_with_tool_use(tmp_dir) do
      path = Path.join(tmp_dir, "fake_engine_progress.sh")

      File.write!(path, """
      #!/usr/bin/env bash
      cat <<'JSON'
      {"type":"system","subtype":"init","cwd":"ignored","session_id":"fixture-session-progress"}
      {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"lib/foo.ex"}}]}}
      {"type":"assistant","message":{"content":[{"type":"text","text":"working on it"}]}}
      {"type":"result","subtype":"success","is_error":false,"result":"All done, added foo","session_id":"fixture-session-progress"}
      JSON
      exit 0
      """)

      File.chmod!(path, 0o755)
      path
    end

    # Exits non-zero after reporting a structured error result - for tests
    # proving the failed-job report shows the engine's own error message.
    defp write_failing_fixture_engine(tmp_dir) do
      path = Path.join(tmp_dir, "fake_engine_fail.sh")

      File.write!(path, """
      #!/usr/bin/env bash
      cat <<'JSON'
      {"type":"system","subtype":"init","cwd":"ignored","session_id":"fixture-session-fail"}
      {"type":"result","subtype":"error","is_error":true,"result":"boom: something broke","session_id":"fixture-session-fail"}
      JSON
      exit 1
      """)

      File.chmod!(path, 0o755)
      path
    end

    # Fakes the push/`gh pr create` commands `create_pr/2` shells out to via
    # `state.cmd_runner`, so the "no push before the Create PR callback"
    # tests never touch a real remote or the `gh` CLI. Runs in the test
    # process itself - Create PR is only ever reached via a callback_query
    # update processed synchronously through handle_update/2 (unlike the job
    # progress/completion notifier, which runs inside JobRunner - see
    # FakeTelegram above).
    defp fake_cmd_runner do
      fn
        "git", args, opts ->
          send(self(), {:cmd, "git", args, opts})
          {"", 0}

        "gh", args, opts ->
          send(self(), {:cmd, "gh", args, opts})
          {"https://github.com/example/repo/pull/42\n", 0}
      end
    end

    defp callback_update(data, message_id \\ 1) do
      %{
        "callback_query" => %{
          "id" => "cbq-#{message_id}",
          "data" => data,
          "message" => %{"chat" => %{"id" => @chat_id}, "message_id" => message_id}
        }
      }
    end

    defp text_message(text, message_id \\ 1) do
      %{
        "message" => %{
          "chat" => %{"id" => @chat_id},
          "message_id" => message_id,
          "text" => text
        }
      }
    end

    defp reply_message(text, reply_to_message_id, message_id \\ 99) do
      %{
        "message" => %{
          "chat" => %{"id" => @chat_id},
          "message_id" => message_id,
          "text" => text,
          "reply_to_message" => %{"message_id" => reply_to_message_id}
        }
      }
    end

    defp wait_for_status(store, job_id, status, attempts \\ 150) do
      job = JobStore.get(store, job_id)

      cond do
        job && job.status == status ->
          job

        attempts <= 0 ->
          flunk(
            "job #{job_id} never reached status #{inspect(status)}, last seen: #{inspect(job)}"
          )

        true ->
          Process.sleep(20)
          wait_for_status(store, job_id, status, attempts - 1)
      end
    end

    # -- /run --

    test "/run launches a claude job in the registered project", %{state: state, store: store} do
      TelegramPoller.handle_update(text_message("/run trainer fix the widget"), state)

      assert_receive {:telegram_send, text}
      assert text =~ "starting"

      assert [job] = JobStore.list(store)
      assert job.engine == "claude"
      assert job.project == "trainer"
      assert job.prompt == "fix the widget"
      assert job.telegram_message_ids != []

      wait_for_status(store, job.id, :completed)
    end

    test "/run codex <project> <prompt> selects the codex engine", %{state: state, store: store} do
      TelegramPoller.handle_update(text_message("/run codex trainer fix the widget"), state)

      assert [job] = JobStore.list(store)
      assert job.engine == "codex"
      assert job.project == "trainer"
      assert job.prompt == "fix the widget"
    end

    test "unauthorized chat_id cannot invoke /run", %{state: state, store: store} do
      unauthorized_update = %{
        "message" => %{
          "chat" => %{"id" => 999_999},
          "message_id" => 1,
          "text" => "/run trainer fix the widget"
        }
      }

      TelegramPoller.handle_update(unauthorized_update, state)

      refute_receive {:telegram_send, _}
      assert JobStore.list(store) == []
    end

    test "unknown project answers with the registry list, no job created", %{
      state: state,
      store: store
    } do
      TelegramPoller.handle_update(text_message("/run not-a-project do the thing"), state)

      assert_receive {:telegram_send, text}
      assert text =~ "trainer"
      assert JobStore.list(store) == []
    end

    test "/run with no prompt gets usage help, no job created", %{state: state, store: store} do
      TelegramPoller.handle_update(text_message("/run trainer"), state)

      assert_receive {:telegram_send, text}
      assert text =~ "Usage"
      assert JobStore.list(store) == []
    end

    test "/run with nothing after it gets usage help, no job created", %{
      state: state,
      store: store
    } do
      TelegramPoller.handle_update(text_message("/run"), state)

      assert_receive {:telegram_send, text}
      assert text =~ "Usage"
      assert JobStore.list(store) == []
    end

    # -- /jobs --

    test "/jobs shows id, engine, project, status", %{state: state, store: store} do
      {:ok, job} = JobStore.create(store, %{engine: "claude", project: "trainer", prompt: "x"})

      TelegramPoller.handle_update(text_message("/jobs"), state)

      assert_receive {:telegram_send, text}
      assert text =~ "claude"
      assert text =~ "trainer"
      assert text =~ "queued"
      assert text =~ to_string(job.id)
    end

    test "/jobs with no jobs yet says so", %{state: state} do
      TelegramPoller.handle_update(text_message("/jobs"), state)

      assert_receive {:telegram_send, text}
      assert text =~ "No jobs"
    end

    # -- /projects --

    test "/projects lists registered projects", %{state: state} do
      TelegramPoller.handle_update(text_message("/projects"), state)

      assert_receive {:telegram_send, text}
      assert text =~ "trainer"
    end

    # -- /cancel <id> --

    test "/cancel <id> stops a running job and marks it discarded", %{
      state: state,
      store: store
    } do
      {:ok, job} =
        JobStore.create(store, %{
          engine: "claude",
          project: "trainer",
          prompt: "FIXTURE_SLOW do the thing"
        })

      opts =
        state.job_launch_opts ++ [job_store: store, project_registry: state.project_registry]

      assert :started = JobSupervisor.start_job(job, opts)

      TelegramPoller.handle_update(text_message("/cancel #{job.id}"), state)

      assert JobStore.get(store, job.id).status == :discarded
      assert_receive {:telegram_send, text}
      assert text =~ "cancelled"
    end

    test "/cancel <id> also works for a still-queued job (no runner yet)", %{
      state: state,
      store: store
    } do
      opts =
        state.job_launch_opts ++ [job_store: store, project_registry: state.project_registry]

      for _ <- 1..3 do
        {:ok, slow_job} =
          JobStore.create(store, %{
            engine: "claude",
            project: "trainer",
            prompt: "FIXTURE_SLOW do the thing"
          })

        assert :started = JobSupervisor.start_job(slow_job, opts)
      end

      {:ok, queued_job} =
        JobStore.create(store, %{engine: "claude", project: "trainer", prompt: "queued job"})

      assert :queued = JobSupervisor.start_job(queued_job, opts)

      TelegramPoller.handle_update(text_message("/cancel #{queued_job.id}"), state)

      assert JobStore.get(store, queued_job.id).status == :discarded
    end

    test "/cancel <id> on an already-terminal job reports it can't be cancelled", %{
      state: state,
      store: store
    } do
      {:ok, job} = JobStore.create(store, %{engine: "claude", project: "trainer", prompt: "x"})
      {:ok, _} = JobStore.update_status(store, job.id, :running, %{})
      {:ok, _} = JobStore.update_status(store, job.id, :completed, %{})

      TelegramPoller.handle_update(text_message("/cancel #{job.id}"), state)

      assert JobStore.get(store, job.id).status == :completed
      assert_receive {:telegram_send, text}
      assert text =~ "completed"
      assert text =~ "cancel"
    end

    test "/cancel with no numeric id keeps the pre-existing escape-shortcut behavior", %{
      state: state,
      store: store
    } do
      # The pre-existing "/cancel" shortcut (send Escape to the selected
      # terminal session) goes through the hardcoded `Telegram` alias, not
      # `state.telegram`, and may auto-select a session left behind by
      # SessionStore (a global, cross-test singleton) - neither is
      # observable or relevant here. What we can and must prove is that the
      # NEW numeric job-cancel branch does not misidentify this as a job
      # cancellation: no job touched, and the job-command fields of state
      # come back unchanged.
      new_state = TelegramPoller.handle_update(text_message("/cancel"), state)

      assert new_state.job_store == state.job_store
      assert new_state.job_launch_opts == state.job_launch_opts
      assert new_state.project_registry == state.project_registry
      assert JobStore.list(store) == []
    end

    # -- Reply-to-job (resume) --

    test "replying to a job's message resumes it with the reply text", %{
      state: state,
      store: store
    } do
      TelegramPoller.handle_update(text_message("/run trainer do the first thing"), state)
      assert_receive {:telegram_send, _starting_text}

      assert [original_job] = JobStore.list(store)
      completed = wait_for_status(store, original_job.id, :completed)
      assert [message_id] = completed.telegram_message_ids

      TelegramPoller.handle_update(
        reply_message("now do the second thing", message_id),
        state
      )

      assert_receive {:telegram_send, resume_text}
      assert resume_text =~ "resuming"

      jobs = JobStore.list(store)
      assert length(jobs) == 2
      assert [new_job] = Enum.reject(jobs, &(&1.id == original_job.id))
      assert new_job.prompt == "now do the second thing"
      assert new_job.engine == "claude"
      assert new_job.project == "trainer"

      wait_for_status(store, new_job.id, :completed)
    end

    test "replying to a still-running job's message reports it can't be resumed yet", %{
      state: state,
      store: store
    } do
      {:ok, job} = JobStore.create(store, %{engine: "claude", project: "trainer", prompt: "x"})
      {:ok, _} = JobStore.update_status(store, job.id, :running, %{telegram_message_ids: [555]})

      TelegramPoller.handle_update(reply_message("please continue", 555), state)

      assert_receive {:telegram_send, text}
      assert text =~ "running"
      assert JobStore.list(store) |> length() == 1
    end

    test "replying to a completed job with no recorded session reports the limitation", %{
      state: state,
      store: store
    } do
      {:ok, job} = JobStore.create(store, %{engine: "claude", project: "trainer", prompt: "x"})
      {:ok, _} = JobStore.update_status(store, job.id, :running, %{telegram_message_ids: [777]})
      {:ok, _} = JobStore.update_status(store, job.id, :completed, %{})

      TelegramPoller.handle_update(reply_message("please continue", 777), state)

      assert_receive {:telegram_send, text}
      assert text =~ "no recorded session"
      assert JobStore.list(store) |> length() == 1
    end

    test "replying to a message not tracked by any job falls back to the regular text command", %{
      state: state
    } do
      # "/help" itself goes through the pre-existing `Telegram` alias, not
      # `state.telegram` - use "/jobs" (this story's own command, already
      # wired to state.telegram) to prove the fallback reached
      # handle_text_command at all, without relying on the real network.
      TelegramPoller.handle_update(reply_message("/jobs", 123_456_789), state)

      assert_receive {:telegram_send, text}
      assert text =~ "No jobs"
    end

    # -- Job progress/completion report (story #235) --

    test "progress edits the same tracked message in place, no extra sends", %{
      state: state,
      store: store,
      tmp_dir: tmp_dir
    } do
      script = write_fixture_engine_with_tool_use(tmp_dir)

      state = %{
        state
        | job_launch_opts: Keyword.put(state.job_launch_opts, :engine_opts, script: script)
      }

      TelegramPoller.handle_update(text_message("/run trainer add a helper"), state)

      assert_receive {:telegram_send, starting_text}
      assert starting_text =~ "starting"

      assert [job] = JobStore.list(store)

      assert_receive {:telegram_edit, message_id, progress_text}, 2000
      assert message_id == hd(job.telegram_message_ids)
      assert progress_text =~ "Reading"
      assert progress_text =~ "foo\\.ex"
      assert progress_text =~ "Actions: 1"

      wait_for_status(store, job.id, :completed)

      assert_receive {:telegram_edit_buttons, ^message_id, completed_text, buttons}, 2000
      assert completed_text =~ "completed"
      assert completed_text =~ "All done, added foo"

      # No NEW message was ever sent for progress/completion - only the one
      # "starting" message, then edited in place. Any further send would
      # show up as a second {:telegram_send, _}.
      refute_receive {:telegram_send, _}

      assert ["Show diff", "jobdiff:" <> _] = Enum.at(buttons, 0)
      assert ["Create PR", "jobpr:" <> _] = Enum.at(buttons, 1)
      assert ["Discard", "jobdiscard:" <> _] = Enum.at(buttons, 2)
    end

    test "Show diff sends the consolidated diff of the job's own commit", %{
      state: state,
      store: store
    } do
      TelegramPoller.handle_update(text_message("/run trainer fix the widget"), state)
      assert_receive {:telegram_send, _starting}
      assert [job] = JobStore.list(store)
      completed = wait_for_status(store, job.id, :completed)

      File.write!(Path.join(completed.worktree_path, "new_file.txt"), "hello from the job\n")
      {_, 0} = System.cmd("git", ["add", "."], cd: completed.worktree_path)

      {_, 0} =
        System.cmd("git", ["commit", "-q", "-m", "job commit"], cd: completed.worktree_path)

      TelegramPoller.handle_update(callback_update("jobdiff:#{job.id}"), state)

      assert_receive {:telegram_send, diff_text}
      assert diff_text =~ "new_file.txt"
    end

    test "Create PR is the only path that pushes, and only after the callback fires", %{
      state: state,
      store: store
    } do
      TelegramPoller.handle_update(text_message("/run trainer fix the widget"), state)
      assert_receive {:telegram_send, _starting}
      assert [job] = JobStore.list(store)
      completed = wait_for_status(store, job.id, :completed)

      refute_receive {:cmd, "git", ["push" | _], _}
      refute_receive {:cmd, "gh", _, _}

      TelegramPoller.handle_update(callback_update("jobpr:#{job.id}"), state)

      assert_receive {:cmd, "git", ["push", "-u", "origin", branch], cwd: worktree_path}
      assert branch == completed.branch
      assert worktree_path == completed.worktree_path

      assert_receive {:cmd, "gh", ["pr", "create", "--title", _title, "--body", _body], _}

      assert_receive {:telegram_send, pr_text}
      assert pr_text =~ "pull/42"
    end

    test "Create PR refuses a job that hasn't completed", %{state: state, store: store} do
      {:ok, job} = JobStore.create(store, %{engine: "claude", project: "trainer", prompt: "x"})
      {:ok, _} = JobStore.update_status(store, job.id, :running, %{})

      TelegramPoller.handle_update(callback_update("jobpr:#{job.id}"), state)

      refute_receive {:cmd, "git", _, _}
      assert_receive {:telegram_send, text}
      assert text =~ "running"
    end

    test "Discard on a completed job removes the worktree and edits the report, status unchanged",
         %{state: state, store: store} do
      TelegramPoller.handle_update(text_message("/run trainer fix the widget"), state)
      assert_receive {:telegram_send, _starting}
      assert [job] = JobStore.list(store)
      completed = wait_for_status(store, job.id, :completed)
      assert File.dir?(completed.worktree_path)

      TelegramPoller.handle_update(callback_update("jobdiscard:#{job.id}"), state)

      refute File.dir?(completed.worktree_path)
      assert JobStore.get(store, job.id).status == :completed

      assert_receive {:telegram_edit_buttons, message_id, text, []}
      assert message_id == hd(completed.telegram_message_ids)
      assert text =~ "discarded"
    end

    test "Discard on a still-running job discards its status too", %{
      state: state,
      store: store
    } do
      {:ok, job} =
        JobStore.create(store, %{
          engine: "claude",
          project: "trainer",
          prompt: "FIXTURE_SLOW do the thing"
        })

      opts = state.job_launch_opts ++ [job_store: store, project_registry: state.project_registry]
      assert :started = JobSupervisor.start_job(job, opts)

      TelegramPoller.handle_update(callback_update("jobdiscard:#{job.id}"), state)

      assert JobStore.get(store, job.id).status == :discarded
    end

    test "a failed job's report includes the engine's error and offers Show output/Discard only",
         %{state: state, store: store, tmp_dir: tmp_dir} do
      script = write_failing_fixture_engine(tmp_dir)

      state = %{
        state
        | job_launch_opts: Keyword.put(state.job_launch_opts, :engine_opts, script: script)
      }

      TelegramPoller.handle_update(text_message("/run trainer break something"), state)
      assert_receive {:telegram_send, _starting}
      assert [job] = JobStore.list(store)
      wait_for_status(store, job.id, :failed)

      assert_receive {:telegram_edit_buttons, _message_id, text, buttons}
      assert text =~ "failed"
      assert text =~ "boom: something broke"
      assert ["Show output", "jobshowoutput:" <> _] = Enum.at(buttons, 0)
      assert ["Discard", "jobdiscard:" <> _] = Enum.at(buttons, 1)
      refute Enum.any?(buttons, fn [label, _] -> label == "Create PR" end)

      TelegramPoller.handle_update(callback_update("jobshowoutput:#{job.id}"), state)
      assert_receive {:telegram_send, output_text}
      assert output_text =~ "boom: something broke"
    end

    # -- Watch mode (story #238) --

    # Same shape as write_fixture_engine_with_tool_use/1, plus an upfront
    # sleep - so a test can reliably tap [Watch]/`/watch` WHILE the job is
    # still :running (before any transcript entry, let alone completion,
    # exists), instead of racing the (otherwise near-instant) fixture
    # engine to a finish line.
    defp write_fixture_engine_with_tool_use_slow(tmp_dir) do
      path = Path.join(tmp_dir, "fake_engine_progress_slow.sh")

      File.write!(path, """
      #!/usr/bin/env bash
      sleep 0.3
      cat <<'JSON'
      {"type":"system","subtype":"init","cwd":"ignored","session_id":"fixture-session-progress-slow"}
      {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"lib/foo.ex"}}]}}
      {"type":"assistant","message":{"content":[{"type":"text","text":"working on it"}]}}
      {"type":"result","subtype":"success","is_error":false,"result":"All done, added foo","session_id":"fixture-session-progress-slow"}
      JSON
      exit 0
      """)

      File.chmod!(path, 0o755)
      path
    end

    test "tapping [Watch] on a running job's activity message starts watching, sends a transcript message, and flips the button to [Unwatch]",
         %{state: state, store: store} do
      TelegramPoller.handle_update(text_message("/run trainer FIXTURE_SLOW do the thing"), state)
      assert_receive {:telegram_send, _starting}
      assert [job] = JobStore.list(store)
      assert job.status == :running

      new_state = TelegramPoller.handle_update(callback_update("jobwatch:#{job.id}"), state)

      assert_receive {:telegram_send, transcript_text}
      assert transcript_text =~ "trainer"
      assert %{message_id: _, dirty: false, timer_ref: nil} = new_state.watches[job.id]

      assert_receive {:telegram_edit_markup, message_id, [["Unwatch", "jobunwatch:" <> id_str]]}
      assert message_id == hd(job.telegram_message_ids)
      assert id_str == to_string(job.id)

      wait_for_status(store, job.id, :completed)
    end

    test "/watch <id> works exactly like tapping the button", %{state: state, store: store} do
      TelegramPoller.handle_update(text_message("/run trainer FIXTURE_SLOW do the thing"), state)
      assert_receive {:telegram_send, _starting}
      assert [job] = JobStore.list(store)

      new_state = TelegramPoller.handle_update(text_message("/watch #{job.id}"), state)

      assert_receive {:telegram_send, transcript_text}
      assert transcript_text =~ "trainer"
      assert Map.has_key?(new_state.watches, job.id)

      wait_for_status(store, job.id, :completed)
    end

    test "/watch with a non-numeric argument reports usage, no crash", %{state: state} do
      TelegramPoller.handle_update(text_message("/watch not-a-number"), state)
      assert_receive {:telegram_send, text}
      assert text =~ "Usage"
    end

    test "watching an unknown job id reports not found", %{state: state} do
      TelegramPoller.handle_update(text_message("/watch 999999"), state)
      assert_receive {:telegram_send, text}
      assert text =~ "not found"
    end

    test "watching the same job twice reports it's already watched", %{
      state: state,
      store: store
    } do
      TelegramPoller.handle_update(text_message("/run trainer FIXTURE_SLOW do the thing"), state)
      assert_receive {:telegram_send, _starting}
      assert [job] = JobStore.list(store)

      new_state = TelegramPoller.handle_update(text_message("/watch #{job.id}"), state)
      assert_receive {:telegram_send, _transcript}
      assert_receive {:telegram_edit_markup, _, _}

      TelegramPoller.handle_update(text_message("/watch #{job.id}"), new_state)
      assert_receive {:telegram_send, text}
      assert text =~ "Already watching"

      wait_for_status(store, job.id, :completed)
    end

    test "a burst of progress events within the throttle window produces at most one transcript edit",
         %{state: state, store: store} do
      previous = Application.get_env(:claude_notify, :watch_edit_interval_ms)
      Application.put_env(:claude_notify, :watch_edit_interval_ms, 50)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:claude_notify, :watch_edit_interval_ms)
          value -> Application.put_env(:claude_notify, :watch_edit_interval_ms, value)
        end
      end)

      {:ok, job} = JobStore.create(store, %{engine: "claude", project: "trainer", prompt: "x"})
      JobTranscript.record(state.job_transcript, job.id, JobTranscript.text_entry("first"))

      watching_state = %{
        state
        | watches: %{job.id => %{message_id: 4242, dirty: false, timer_ref: nil}}
      }

      {:noreply, s1} = TelegramPoller.handle_info({:watch_progress, job.id}, watching_state)
      assert s1.watches[job.id].timer_ref != nil

      {:noreply, s2} = TelegramPoller.handle_info({:watch_progress, job.id}, s1)
      {:noreply, s3} = TelegramPoller.handle_info({:watch_progress, job.id}, s2)
      assert s3.watches[job.id].timer_ref == s1.watches[job.id].timer_ref

      assert_receive {:watch_flush, flushed_job_id}, 500
      assert flushed_job_id == job.id

      {:noreply, _s4} = TelegramPoller.handle_info({:watch_flush, job.id}, s3)

      assert_receive {:telegram_edit, 4242, text}
      assert text =~ "first"
      refute_receive {:telegram_edit, 4242, _}
    end

    test "/unwatch stops further edits: no Telegram calls after unwatch despite new progress events",
         %{state: state, store: store} do
      {:ok, job} =
        JobStore.create(store, %{
          engine: "claude",
          project: "trainer",
          prompt: "x",
          telegram_message_ids: [111]
        })

      JobTranscript.record(state.job_transcript, job.id, JobTranscript.text_entry("hello"))

      watching_state = %{
        state
        | watches: %{job.id => %{message_id: 4343, dirty: false, timer_ref: nil}}
      }

      new_state = TelegramPoller.handle_update(text_message("/unwatch #{job.id}"), watching_state)

      refute Map.has_key?(new_state.watches, job.id)
      assert_receive {:telegram_edit, 4343, finalize_text}
      assert finalize_text =~ "hello"
      assert_receive {:telegram_edit_markup, _message_id, [["Watch", "jobwatch:" <> _]]}

      {:noreply, after_progress} =
        TelegramPoller.handle_info({:watch_progress, job.id}, new_state)

      assert after_progress == new_state
      refute_receive {:telegram_edit, 4343, _}
      refute_receive {:telegram_edit_markup, _, _}
    end

    test "/unwatch on a job that isn't being watched says so", %{state: state, store: store} do
      {:ok, job} = JobStore.create(store, %{engine: "claude", project: "trainer", prompt: "x"})

      TelegramPoller.handle_update(text_message("/unwatch #{job.id}"), state)
      assert_receive {:telegram_send, text}
      assert text =~ "not being watched"
    end

    test "a :watch_progress event for an unwatched job makes no Telegram calls", %{state: state} do
      {:noreply, new_state} = TelegramPoller.handle_info({:watch_progress, 999_999}, state)
      assert new_state == state
      refute_receive {:telegram_edit, _, _}
      refute_receive {:telegram_edit_markup, _, _}
    end

    test "job completion while watched finalizes the transcript message with the final content",
         %{state: state, store: store, tmp_dir: tmp_dir} do
      script = write_fixture_engine_with_tool_use_slow(tmp_dir)

      state = %{
        state
        | job_launch_opts: Keyword.put(state.job_launch_opts, :engine_opts, script: script)
      }

      TelegramPoller.handle_update(text_message("/run trainer add a helper"), state)
      assert_receive {:telegram_send, _starting}
      assert [job] = JobStore.list(store)
      job_id = job.id

      new_state = TelegramPoller.handle_update(callback_update("jobwatch:#{job_id}"), state)
      assert_receive {:telegram_send, _transcript}
      assert_receive {:telegram_edit_markup, _message_id, [["Unwatch", "jobunwatch:" <> _]]}
      assert %{message_id: transcript_message_id} = new_state.watches[job_id]

      assert_receive {:watch_completed, ^job_id, transcript}, 2000

      {:noreply, final_state} =
        TelegramPoller.handle_info({:watch_completed, job_id, transcript}, new_state)

      refute Map.has_key?(final_state.watches, job_id)
      assert_receive {:telegram_edit, ^transcript_message_id, final_text}
      assert final_text =~ "Read"
      assert final_text =~ "foo\\.ex"

      wait_for_status(store, job_id, :completed)
    end

    test "watching an already-terminal job whose transcript was already discarded gets the honest 'gone' reply",
         %{state: state, store: store} do
      TelegramPoller.handle_update(text_message("/run trainer fix the widget"), state)
      assert_receive {:telegram_send, _starting}
      assert [job] = JobStore.list(store)
      wait_for_status(store, job.id, :completed)

      TelegramPoller.handle_update(text_message("/watch #{job.id}"), state)

      assert_receive {:telegram_send, text}
      assert text =~ "gone"
    end

    test "watching an already-terminal job whose transcript is still available gets a static snapshot, not a live watch",
         %{state: state, store: store} do
      {:ok, job} = JobStore.create(store, %{engine: "claude", project: "trainer", prompt: "x"})
      {:ok, _} = JobStore.update_status(store, job.id, :running, %{})
      {:ok, job} = JobStore.update_status(store, job.id, :completed, %{})

      JobTranscript.record(state.job_transcript, job.id, JobTranscript.text_entry("late arrival"))

      new_state = TelegramPoller.handle_update(text_message("/watch #{job.id}"), state)

      assert_receive {:telegram_send, text}
      assert text =~ "late arrival"
      refute text =~ "gone"
      refute Map.has_key?(new_state.watches, job.id)
    end
  end

  describe "shortcut_response/1" do
    test "recognizes affirmative variants" do
      assert TelegramPoller.shortcut_response("yes") == "yes"
      assert TelegramPoller.shortcut_response("y") == "yes"
      assert TelegramPoller.shortcut_response("Y") == "yes"
      assert TelegramPoller.shortcut_response("approve") == "yes"
      assert TelegramPoller.shortcut_response("  ok  ") == "yes"
    end

    test "recognizes don't-ask variants" do
      assert TelegramPoller.shortcut_response("yes!") == "yes_dont_ask"
      assert TelegramPoller.shortcut_response("yda") == "yes_dont_ask"
    end

    test "recognizes negative variants" do
      assert TelegramPoller.shortcut_response("no") == "no"
      assert TelegramPoller.shortcut_response("n") == "no"
      assert TelegramPoller.shortcut_response("DENY") == "no"
    end

    test "recognizes escape variants" do
      assert TelegramPoller.shortcut_response("esc") == "escape"
      assert TelegramPoller.shortcut_response("escape") == "escape"
      assert TelegramPoller.shortcut_response("cancel") == "escape"
    end

    test "recognizes single digits 1-9 as numbered options" do
      assert TelegramPoller.shortcut_response("1") == "opt_1"
      assert TelegramPoller.shortcut_response("9") == "opt_9"
      assert TelegramPoller.shortcut_response(" 5 ") == "opt_5"
    end

    test "returns nil for free-form text" do
      assert TelegramPoller.shortcut_response("yes please continue") == nil
      assert TelegramPoller.shortcut_response("hello world") == nil
      assert TelegramPoller.shortcut_response("") == nil
      assert TelegramPoller.shortcut_response("0") == nil
    end
  end
end
