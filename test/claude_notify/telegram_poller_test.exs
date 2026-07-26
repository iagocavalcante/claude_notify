defmodule ClaudeNotify.TelegramPollerTest do
  use ExUnit.Case, async: false

  alias ClaudeNotify.{
    TelegramPoller,
    SessionStore,
    JobStore,
    JobSupervisor,
    ProjectRegistry
  }

  @moduletag :tmp_dir

  # Records sent Telegram texts to the test process instead of hitting the
  # network - same rationale/shape as JobReconcilerTest's FakeTelegram.
  defmodule FakeTelegram do
    def send_message(text) do
      send(self(), {:telegram_send, text})
      {:ok, %{"result" => %{"message_id" => System.unique_integer([:positive, :monotonic])}}}
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

      state = %{
        offset: 0,
        selected_sessions: %{},
        telegram: FakeTelegram,
        job_store: store,
        project_registry: registry,
        job_launch_opts: job_launch_opts
      }

      %{store: store, registry: registry, state: state}
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
  end
end
