defmodule ClaudeNotify.TelegramPollerTest do
  use ExUnit.Case, async: false

  alias ClaudeNotify.{
    TelegramPoller,
    SessionStore,
    ConversationStore,
    JobStore,
    JobSupervisor,
    JobTranscript,
    MemoryPages,
    ProjectRegistry,
    ProjectScope
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

    # Retry-safe counterpart adopted by every job/watch call site (story
    # #241) - real chunking behavior (via the actual
    # `ClaudeNotify.Telegram.chunk/2`, a pure function safe to reuse here),
    # each resulting piece forwarded as its own `{:telegram_send, text}` so
    # a chunked "Show diff"/"Show output" shows up as multiple ordered
    # messages in tests, exactly like it does in production. 429-retry
    # itself is exercised at the unit level against the real
    # `ClaudeNotify.Telegram` module (see telegram_test.exs) - this double
    # only needs to reproduce the OBSERVABLE chunking/ordering behavior.
    def send_message_with_retry(text) do
      case ClaudeNotify.Telegram.chunk(text) do
        [single] ->
          send_message(single)

        [first | rest] ->
          result = send_message(first)
          Enum.each(rest, &send_message/1)
          result
      end
    end

    def send_html_with_retry(text) do
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

    # Same chunking rationale as send_message_with_retry/1 above - leading
    # chunks (if any) are plain sends, buttons stay attached to the last.
    def send_with_buttons_retry(text, buttons) do
      case ClaudeNotify.Telegram.chunk(text) do
        [single] ->
          send_with_buttons(single, buttons)

        chunks ->
          {leading, [last]} = Enum.split(chunks, length(chunks) - 1)
          Enum.each(leading, &send_message/1)
          send_with_buttons(last, buttons)
      end
    end

    def send_with_button_rows_retry(text, rows) do
      forward({:telegram_button_rows, rows})
      send_message(text)
    end

    def edit_message_text(message_id, text) do
      forward({:telegram_edit, message_id, text})
      {:ok, %{"result" => %{"message_id" => message_id}}}
    end

    # Edits are never chunked (a single Telegram message can't be split
    # into several while staying one edit target) - a plain passthrough is
    # enough to prove call-site adoption.
    def edit_message_text_with_retry(message_id, text), do: edit_message_text(message_id, text)

    def edit_message_text_with_buttons(message_id, text, buttons) do
      forward({:telegram_edit_buttons, message_id, text, buttons})
      {:ok, %{"result" => %{"message_id" => message_id}}}
    end

    def edit_message_text_with_buttons_with_retry(message_id, text, buttons),
      do: edit_message_text_with_buttons(message_id, text, buttons)

    def edit_message_text_with_buttons_html_retry(message_id, text, buttons),
      do: edit_message_text_with_buttons(message_id, text, buttons)

    def edit_message_reply_markup(message_id, buttons) do
      forward({:telegram_edit_markup, message_id, buttons})
      {:ok, %{"result" => %{"message_id" => message_id}}}
    end

    def edit_message_reply_markup_with_retry(message_id, buttons),
      do: edit_message_reply_markup(message_id, buttons)

    def send_chat_action(chat_id, action) do
      forward({:telegram_chat_action, chat_id, action})
      {:ok, %{"result" => true}}
    end

    def answer_callback_query(callback_id, text \\ nil) do
      forward({:telegram_callback_answer, callback_id, text})
      {:ok, %{"result" => true}}
    end

    # Minimal addition for story #242 (native command menu) - forwards the
    # exact command list so tests can assert register_bot_commands/1 sends
    # everything in one call, same observability shape as every other
    # function here.
    def set_my_commands(commands) do
      forward({:telegram_set_my_commands, commands})
      {:ok, %{"result" => true}}
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
  # Returns {:error, :boom} instead of registering anything - just enough of
  # the telegram module surface for register_bot_commands/1 to call into, to
  # prove a failed setMyCommands (story #242) is logged and non-fatal.
  defmodule FailingTelegram do
    def set_my_commands(_commands), do: {:error, :boom}
  end

  defmodule FakeTerminalInjector do
    def send_text(tty_path, text) do
      case Process.whereis(:telegram_poller_test_process) do
        nil -> send(self(), {:terminal_text, tty_path, text})
        pid -> send(pid, {:terminal_text, tty_path, text})
      end

      :ok
    end

    def send_response(tty_path, response) do
      case Process.whereis(:telegram_poller_test_process) do
        nil -> send(self(), {:terminal_response, tty_path, response})
        pid -> send(pid, {:terminal_response, tty_path, response})
      end

      :ok
    end
  end

  defmodule FakePreviewManager do
    def start_preview(_server, job) do
      forward({:preview_started, job.id})

      {:ok,
       %{
         id: 9,
         job_id: job.id,
         provider: :cloudflare,
         access: :otp,
         url: "https://preview-#{job.id}.example.com",
         expires_at: System.system_time(:second) + 3_600
       }}
    end

    def start_preview(_server, job, provider) do
      forward({:preview_started, job.id, provider})

      {:ok,
       %{
         id: 10,
         job_id: job.id,
         provider: :tailscale,
         access: :tailnet,
         url: "https://devbox.example.ts.net:44300",
         expires_at: System.system_time(:second) + 3_600
       }}
    end

    def list(_server) do
      [
        %{
          id: 9,
          job_id: 42,
          url: "https://preview-42.example.com",
          expires_at: System.system_time(:second) + 3_600
        }
      ]
    end

    def stop_preview(_server, id) do
      forward({:preview_stopped, id})
      {:ok, %{id: id}}
    end

    defp forward(message) do
      case Process.whereis(:telegram_poller_test_process) do
        nil -> send(self(), message)
        pid -> send(pid, message)
      end
    end
  end

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
    SessionStore.clear()

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

  describe "command menu (story #242)" do
    import ExUnit.CaptureLog

    test "bot_commands/0 covers the full current surface, README-aligned" do
      commands = TelegramPoller.bot_commands()

      assert Enum.map(commands, &elem(&1, 0)) == ~w(
               new agent fresh sessions history approve cancel dashboard run jobs projects memory watch unwatch
               preview previews unpreview help
             )

      assert Enum.all?(commands, fn {command, description} ->
               command =~ ~r/^[a-z0-9_]{1,32}$/ and String.length(description) in 3..256
             end)
    end

    test "boot registers exactly one setMyCommands call carrying every command with a description" do
      state = %{telegram: FakeTelegram}

      assert {:noreply, ^state} = TelegramPoller.handle_info(:register_commands, state)

      expected =
        Enum.map(TelegramPoller.bot_commands(), fn {command, description} ->
          %{command: command, description: description}
        end)

      assert_received {:telegram_set_my_commands, ^expected}
      refute_received {:telegram_set_my_commands, _}
    end

    test "a failing setMyCommands is logged and does not crash the poller" do
      state = %{telegram: FailingTelegram}

      log =
        capture_log(fn ->
          assert {:noreply, ^state} = TelegramPoller.handle_info(:register_commands, state)
        end)

      assert log =~ "setMyCommands failed"
      assert log =~ ":boom"
    end
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

      conversation_store = :"conversation_store_#{System.unique_integer([:positive])}"

      start_supervised!(
        {ConversationStore,
         name: conversation_store, path: Path.join(tmp_dir, "conversations.dat")}
      )

      state = %{
        offset: 0,
        selected_sessions: %{},
        telegram: FakeTelegram,
        terminal_injector: FakeTerminalInjector,
        job_store: store,
        conversation_store: conversation_store,
        job_transcript: transcript,
        project_registry: registry,
        job_launch_opts: job_launch_opts,
        cmd_runner: fake_cmd_runner(),
        watches: %{}
      }

      %{store: store, registry: registry, transcript: transcript, state: state}
    end

    # -- Fixtures / helpers --

    defp select_trainer(state) do
      token =
        :crypto.hash(:sha256, "trainer")
        |> Base.encode16(case: :lower)
        |> String.slice(0, 12)

      TelegramPoller.handle_update(callback_update("project:#{token}"), state)
    end

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

    # Same shape as write_failing_fixture_engine/1, but with a caller-supplied
    # `error_message` long enough to exceed Telegram's 4096-char limit once
    # formatted - for proving Show output chunks instead of truncating (story
    # #241). No literal newlines/quotes in `error_message`: it's spliced
    # directly into a single-line JSON string.
    defp write_failing_fixture_engine_with_long_error(tmp_dir, error_message) do
      path = Path.join(tmp_dir, "fake_engine_fail_long.sh")

      File.write!(path, """
      #!/usr/bin/env bash
      cat <<'JSON'
      {"type":"system","subtype":"init","cwd":"ignored","session_id":"fixture-session-fail-long"}
      {"type":"result","subtype":"error","is_error":true,"result":"#{error_message}","session_id":"fixture-session-fail-long"}
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

    defp callback_update(data, message_id \\ 1, text \\ nil) do
      message =
        %{"chat" => %{"id" => @chat_id}, "message_id" => message_id}
        |> then(fn message ->
          if is_binary(text), do: Map.put(message, "text", text), else: message
        end)

      %{
        "callback_query" => %{
          "id" => "cbq-#{message_id}",
          "data" => data,
          "message" => message
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

    defp wait_for_transcript_discard(transcript, job_id, attempts \\ 100) do
      cond do
        JobTranscript.transcript(transcript, job_id) == [] ->
          :ok

        attempts <= 0 ->
          flunk("job #{job_id} transcript was not discarded")

        true ->
          Process.sleep(10)
          wait_for_transcript_discard(transcript, job_id, attempts - 1)
      end
    end

    # Drains every pending `{:telegram_send, text}` already in the test
    # process's mailbox, in receive order - for proving a chunked send
    # (story #241) arrived as several ordered messages instead of one. A
    # short timeout is enough: by the time a job/watch handler call
    # returns, every one of its (synchronous, in-process) FakeTelegram
    # sends has already been delivered.
    defp collect_telegram_sends(timeout \\ 200) do
      receive do
        {:telegram_send, text} -> [text | collect_telegram_sends(timeout)]
      after
        timeout -> []
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

    test "an unrecognized slash command is forwarded as a project skill", %{
      state: state,
      store: store
    } do
      state =
        Map.put(state, :selected_projects, %{@chat_id => "trainer"})

      TelegramPoller.handle_update(text_message("/post-shorts publish the latest clip"), state)

      assert [job] = JobStore.list(store)
      assert job.engine == "claude"
      assert job.project == "trainer"
      assert job.prompt == "/post-shorts publish the latest clip"
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

    test "/preview creates an OTP-protected preview for a known job", %{
      state: state,
      store: store
    } do
      {:ok, job} = JobStore.create(store, %{engine: "claude", project: "trainer", prompt: "web"})
      state = Map.merge(state, %{preview_module: FakePreviewManager, preview_manager: :fake})

      TelegramPoller.handle_update(text_message("/preview #{job.id}"), state)

      assert_receive {:preview_started, job_id}
      assert job_id == job.id
      assert_receive {:telegram_send, text}
      assert text =~ "href=\"https://preview-#{job.id}.example.com\""
      assert text =~ "one-time PIN"
    end

    test "/previews lists active URLs and /unpreview removes one", %{state: state} do
      state = Map.merge(state, %{preview_module: FakePreviewManager, preview_manager: :fake})

      TelegramPoller.handle_update(text_message("/previews"), state)
      assert_receive {:telegram_send, list_text}
      assert list_text =~ "href=\"https://preview-42.example.com\""

      TelegramPoller.handle_update(text_message("/unpreview 9"), state)
      assert_receive {:preview_stopped, 9}
      assert_receive {:telegram_send, stopped_text}
      assert stopped_text =~ "Preview \\#9 stopped"
    end

    test "/preview accepts an explicit Tailscale provider", %{state: state, store: store} do
      {:ok, job} = JobStore.create(store, %{engine: "codex", project: "trainer", prompt: "web"})
      state = Map.merge(state, %{preview_module: FakePreviewManager, preview_manager: :fake})

      TelegramPoller.handle_update(text_message("/preview #{job.id} tailscale"), state)

      assert_receive {:preview_started, job_id, "tailscale"}
      assert job_id == job.id
      assert_receive {:telegram_send, text}
      assert text =~ "href=\"https://devbox.example.ts.net:44300\""
      assert text =~ "Tailscale policy"
    end

    test "/jobs with no jobs yet says so", %{state: state} do
      TelegramPoller.handle_update(text_message("/jobs"), state)

      assert_receive {:telegram_send, text}
      assert text =~ "No jobs"
    end

    # -- /projects --

    test "/projects lists registered projects", %{state: state} do
      TelegramPoller.handle_update(text_message("/projects"), state)

      assert_receive {:telegram_button_rows, rows}
      assert inspect(rows) =~ "trainer"
      assert_receive {:telegram_send, text}
      assert text =~ "Choose a project"
    end

    test "/memory search, recent, brief, and status use the selected canonical project", %{
      state: state,
      registry: registry,
      tmp_dir: tmp_dir
    } do
      pages = :"telegram_memory_pages_#{System.unique_integer([:positive])}"

      start_supervised!(
        {MemoryPages,
         name: pages, root: Path.join(tmp_dir, "telegram-memory"), handoff_store: nil}
      )

      {:ok, scope} = ProjectScope.for_project(registry, "trainer")

      assert {:ok, :inserted, _page} =
               MemoryPages.write_episode(pages, scope, %{
                 completion_key: "telegram-memory-one",
                 source: :terminal,
                 engine: "claude",
                 session_id: "terminal-memory",
                 summary: "Lexical previews are durable and searchable.",
                 next_steps: ["Verify Telegram retrieval."],
                 created_at: 1_800_000_000_000
               })

      memory_state =
        state
        |> Map.put(:memory_pages, pages)
        |> Map.put(:selected_projects, %{@chat_id => "trainer"})

      TelegramPoller.handle_update(text_message("/memory lexical previews"), memory_state)
      assert_receive {:telegram_send, search_text}
      assert search_text =~ "Lexical previews"
      assert search_text =~ "Source:"

      TelegramPoller.handle_update(text_message("/memory recent"), memory_state)
      assert_receive {:telegram_send, recent_text}
      assert recent_text =~ "recent memory"

      TelegramPoller.handle_update(text_message("/memory brief"), memory_state)
      assert_receive {:telegram_send, brief_text}
      assert brief_text =~ "Project memory briefing"

      TelegramPoller.handle_update(text_message("/memory status"), memory_state)
      assert_receive {:telegram_send, status_text}
      assert status_text =~ "Source pages: 1"
      assert status_text =~ "Index: healthy"
    end

    test "/new lets a user choose a project and launch by sending a normal message", %{
      state: state,
      store: store
    } do
      TelegramPoller.handle_update(text_message("/new"), state)

      assert_receive {:telegram_button_rows, [[["trainer" <> _, callback_data]] | _]}
      assert callback_data =~ "project:"
      assert_receive {:telegram_send, picker_text}
      assert picker_text =~ "Choose a project"

      selected_state = TelegramPoller.handle_update(callback_update(callback_data), state)
      assert selected_state.selected_projects[@chat_id] == "trainer"
      assert selected_state.selected_engines[@chat_id] == "claude"
      assert_receive {:telegram_send, selected_text}
      assert selected_text =~ "Send a normal message"

      TelegramPoller.handle_update(text_message("fix the conversational flow"), selected_state)

      assert_receive {:telegram_send, starting_text}
      assert starting_text =~ "starting"
      assert [job] = JobStore.list(store)
      assert job.project == "trainer"
      assert job.engine == "claude"
      assert job.prompt == "fix the conversational flow"

      wait_for_status(store, job.id, :completed)
    end

    test "agent picker changes future conversational tasks to Codex", %{
      state: state,
      store: store
    } do
      token =
        :crypto.hash(:sha256, "trainer")
        |> Base.encode16(case: :lower)
        |> String.slice(0, 12)

      selected_state =
        TelegramPoller.handle_update(callback_update("project:#{token}"), state)

      assert_receive {:telegram_send, _selected_text}

      codex_state =
        TelegramPoller.handle_update(callback_update("engine:codex"), selected_state)

      assert codex_state.selected_engines[@chat_id] == "codex"
      assert_receive {:telegram_send, engine_text}
      assert engine_text =~ "Codex will handle the next turn"

      TelegramPoller.handle_update(text_message("review this repository"), codex_state)
      assert [job] = JobStore.list(store)
      assert job.engine == "codex"
      assert job.prompt == "review this repository"
    end

    test "ordinary follow-ups resume the native agent in the exact same worktree", %{
      state: state,
      store: store
    } do
      selected_state = select_trainer(state)
      assert_receive {:telegram_send, _selected_text}

      first_state =
        TelegramPoller.handle_update(text_message("make the first change"), selected_state)

      assert_receive {:telegram_send, _starting_text}
      [first] = JobStore.list(store)
      completed = wait_for_status(store, first.id, :completed)

      TelegramPoller.handle_update(text_message("now refine it"), first_state)
      assert_receive {:telegram_send, continuation_text}
      assert continuation_text =~ "continuing the conversation"

      [_, second] = JobStore.list(store)
      second = wait_for_status(store, second.id, :completed)

      assert second.parent_job_id == completed.id
      assert second.worktree_path == completed.worktree_path
      assert second.branch == completed.branch
      assert File.read!(Path.join(second.worktree_path, ".received-prompt")) == "--resume\n"
    end

    test "follow-ups sent while busy queue and launch automatically after completion", %{
      state: state,
      store: store
    } do
      selected_state = select_trainer(state)
      assert_receive {:telegram_send, _selected_text}

      working_state =
        TelegramPoller.handle_update(text_message("FIXTURE_SLOW first turn"), selected_state)

      assert_receive {:telegram_send, _starting_text}
      [first] = JobStore.list(store)

      queued_state =
        TelegramPoller.handle_update(text_message("then do the follow-up"), working_state)

      assert_receive {:telegram_send, queued_text}
      assert queued_text =~ "Queued as the next chat turn"
      assert JobStore.list(store) |> length() == 1

      wait_for_status(store, first.id, :completed)
      assert_receive {:watch_completed, first_id, transcript}, 1_000
      assert first_id == first.id

      assert {:noreply, _state} =
               TelegramPoller.handle_info({:watch_completed, first_id, transcript}, queued_state)

      [completed, second] = JobStore.list(store)
      second = wait_for_status(store, second.id, :completed)
      assert second.parent_job_id == completed.id
      assert second.worktree_path == completed.worktree_path

      assert %{head_job_id: head, pending: []} =
               ConversationStore.get(state.conversation_store, @chat_id)

      assert head == second.id
    end

    test "switching from Claude to Codex hands off the same workspace without native resume", %{
      state: state,
      store: store
    } do
      selected_state = select_trainer(state)
      assert_receive {:telegram_send, _selected_text}

      first_state =
        TelegramPoller.handle_update(text_message("prepare the workspace"), selected_state)

      assert_receive {:telegram_send, _starting_text}
      [first] = JobStore.list(store)
      first = wait_for_status(store, first.id, :completed)

      codex_state = TelegramPoller.handle_update(text_message("/agent codex"), first_state)
      assert_receive {:telegram_send, agent_text}
      assert agent_text =~ "Codex will handle the next turn"

      TelegramPoller.handle_update(text_message("review Claude's work"), codex_state)
      assert_receive {:telegram_send, handoff_text}
      assert handoff_text =~ "handoff from Claude to Codex"

      [_, second] = JobStore.list(store)
      second = wait_for_status(store, second.id, :completed)
      assert second.engine == "codex"
      assert second.parent_job_id == first.id
      assert second.worktree_path == first.worktree_path
      refute File.read!(Path.join(second.worktree_path, ".received-prompt")) == "--resume\n"
    end

    test "/fresh makes the next message start a new isolated conversation workspace", %{
      state: state,
      store: store
    } do
      selected_state = select_trainer(state)
      assert_receive {:telegram_send, _selected_text}

      first_state =
        TelegramPoller.handle_update(text_message("first conversation"), selected_state)

      assert_receive {:telegram_send, _starting_text}
      [first] = JobStore.list(store)
      first = wait_for_status(store, first.id, :completed)

      fresh_state = TelegramPoller.handle_update(text_message("/fresh"), first_state)
      assert_receive {:telegram_send, fresh_text}
      assert fresh_text =~ "Fresh conversation ready"

      TelegramPoller.handle_update(text_message("different conversation"), fresh_state)
      assert_receive {:telegram_send, _starting_text}
      [_, second] = JobStore.list(store)
      second = wait_for_status(store, second.id, :completed)

      assert second.parent_job_id == nil
      refute second.worktree_path == first.worktree_path
    end

    test "standalone yes/no shortcuts use response keystrokes instead of text injection", %{
      state: state
    } do
      session_id = "shortcut-#{System.unique_integer([:positive])}"
      tty_path = "/dev/ttys321"

      SessionStore.register_prompt(session_id, "waiting", "/tmp/project", %{
        "tty_path" => tty_path
      })

      on_exit(fn -> SessionStore.remove_session(session_id) end)

      state = %{state | selected_sessions: %{@chat_id => session_id}}

      for {text, expected} <- [{"yes", "yes"}, {"no", "no"}, {"yes!", "yes_dont_ask"}] do
        assert TelegramPoller.handle_update(text_message(text), state) == state
        assert_receive {:terminal_response, ^tty_path, ^expected}
        assert_receive {:telegram_send, confirmation}
        assert confirmation =~ "Sent"
      end
    end

    test "permission button leaves persistent feedback and cannot inject twice", %{state: state} do
      session_id = "permission-#{System.unique_integer([:positive])}"
      tty_path = "/dev/ttys325"

      SessionStore.register_prompt(session_id, "waiting", "/tmp/project", %{
        "tty_path" => tty_path,
        "engine" => "codex"
      })

      SessionStore.update_status(session_id, :waiting_input, %{
        pending_question_message_id: 333
      })

      on_exit(fn -> SessionStore.remove_session(session_id) end)

      update =
        callback_update(
          "#{session_id}:yes",
          333,
          "Codex Question\n\nAllow Bash?\n\nSession: #{String.slice(session_id, 0, 8)}"
        )

      assert TelegramPoller.handle_update(update, state) == state
      assert_receive {:terminal_response, ^tty_path, "yes"}
      assert_receive {:telegram_callback_answer, "cbq-333", "✅ Allowed"}
      assert_receive {:telegram_edit_buttons, 333, edited, []}
      assert edited =~ "Allow Bash?"
      assert edited =~ "✅ Allowed"

      session = SessionStore.get_session(session_id)
      assert session.status == :active
      assert session.pending_question_message_id == nil
      assert session.last_answered_question_id == 333

      TelegramPoller.handle_update(update, state)
      assert_receive {:telegram_callback_answer, "cbq-333", "Already answered"}
      refute_receive {:terminal_response, ^tty_path, "yes"}, 50
    end

    test "terminal chat sends quietly and reuses the Telegram message as the prompt", %{
      state: state
    } do
      session_id = "chat-#{System.unique_integer([:positive])}"
      tty_path = "/dev/ttys322"

      SessionStore.register_prompt(session_id, "first", "/tmp/project", %{
        "tty_path" => tty_path,
        "engine" => "codex"
      })

      on_exit(fn -> SessionStore.remove_session(session_id) end)

      state = %{state | selected_sessions: %{@chat_id => session_id}}
      new_state = TelegramPoller.handle_update(text_message("keep going", 222), state)

      assert_receive {:terminal_text, ^tty_path, "keep going"}
      refute_receive {:telegram_send, _text}, 50
      assert new_state.selected_sessions[@chat_id] == session_id
      assert SessionStore.bound_session(@chat_id) == session_id
      assert SessionStore.lookup_session_by_message(222) == session_id
      assert SessionStore.get_session(session_id).prompt_message_id == 222
    end

    test "persisted terminal binding routes a new poller state after restart", %{state: state} do
      session_id = "bound-#{System.unique_integer([:positive])}"
      tty_path = "/dev/ttys323"

      SessionStore.register_prompt(session_id, "first", "/tmp/project", %{
        "tty_path" => tty_path
      })

      SessionStore.bind_chat(@chat_id, session_id)
      on_exit(fn -> SessionStore.remove_session(session_id) end)

      TelegramPoller.handle_update(text_message("resume here", 223), state)

      assert_receive {:terminal_text, ^tty_path, "resume here"}
      assert SessionStore.lookup_session_by_message(223) == session_id
    end

    test "/history renders recent user and assistant chat", %{state: state} do
      session_id = "history-#{System.unique_integer([:positive])}"

      SessionStore.register_prompt(session_id, "inspect it", "/tmp/project", %{
        "tty_path" => "/dev/ttys324",
        "engine" => "codex"
      })

      {:ok, ["I found the cause."]} =
        SessionStore.record_assistant_messages(session_id, "", 0, ["I found the cause."])

      SessionStore.bind_chat(@chat_id, session_id)
      on_exit(fn -> SessionStore.remove_session(session_id) end)

      TelegramPoller.handle_update(text_message("/history", 224), state)

      assert_receive {:telegram_send, history}
      assert history =~ "inspect it"
      assert history =~ "I found the cause."
      assert history =~ "Codex"
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
      assert resume_text =~ "continuing the conversation"

      jobs = JobStore.list(store)
      assert length(jobs) == 2
      assert [new_job] = Enum.reject(jobs, &(&1.id == original_job.id))
      assert new_job.prompt == "now do the second thing"
      assert new_job.engine == "claude"
      assert new_job.project == "trainer"

      new_job = wait_for_status(store, new_job.id, :completed)
      assert new_job.parent_job_id == original_job.id
      assert new_job.worktree_path == completed.worktree_path
      assert new_job.branch == completed.branch
    end

    test "replying to a still-running job durably queues the next turn", %{
      state: state,
      store: store
    } do
      {:ok, job} = JobStore.create(store, %{engine: "claude", project: "trainer", prompt: "x"})
      {:ok, _} = JobStore.update_status(store, job.id, :running, %{telegram_message_ids: [555]})

      TelegramPoller.handle_update(reply_message("please continue", 555), state)

      assert_receive {:telegram_send, text}
      assert text =~ "Queued as the next chat turn"
      assert JobStore.list(store) |> length() == 1

      assert %{pending: [%{prompt: "please continue"}]} =
               ConversationStore.get(state.conversation_store, @chat_id)
    end

    test "a completed job with no native session continues safely as a fresh engine turn", %{
      state: state,
      store: store
    } do
      {:ok, job} = JobStore.create(store, %{engine: "claude", project: "trainer", prompt: "x"})
      {:ok, _} = JobStore.update_status(store, job.id, :running, %{telegram_message_ids: [777]})
      {:ok, _} = JobStore.update_status(store, job.id, :completed, %{})

      TelegramPoller.handle_update(reply_message("please continue", 777), state)

      assert_receive {:telegram_send, text}
      assert text =~ "continuing the conversation"
      assert [completed, continuation] = JobStore.list(store)
      assert completed.id == job.id
      assert continuation.parent_job_id == job.id
      wait_for_status(store, continuation.id, :completed)
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
      assert ["Preview", "jobpreview:" <> _] = Enum.at(buttons, 1)
      assert ["Create PR", "jobpr:" <> _] = Enum.at(buttons, 2)
      assert ["Discard", "jobdiscard:" <> _] = Enum.at(buttons, 3)
    end

    test "a job completion report fires a typing indicator before the card is edited in", %{
      state: state,
      store: store
    } do
      TelegramPoller.handle_update(text_message("/run trainer fix the widget"), state)
      assert_receive {:telegram_send, _starting}
      assert [job] = JobStore.list(store)

      wait_for_status(store, job.id, :completed)

      assert_receive {:telegram_chat_action, @chat_id, "typing"}, 2000
      assert_receive {:telegram_edit_buttons, _message_id, _text, _buttons}, 2000
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

    # Story #241: chunking replaces the old silent-truncation behavior.
    test "Show diff longer than Telegram's limit arrives as multiple ordered, size-bounded messages instead of being silently truncated",
         %{state: state, store: store} do
      TelegramPoller.handle_update(text_message("/run trainer fix the widget"), state)
      assert_receive {:telegram_send, _starting}
      assert [job] = JobStore.list(store)
      completed = wait_for_status(store, job.id, :completed)

      # A synthetic diff whose formatted (pre-blocked) size comfortably
      # exceeds Telegram's 4096-char limit, so `MessageFormatter.diff_summary/1`
      # not truncating internally actually gets exercised end to end
      # through the retry-safe chunking send.
      lines = Enum.map(1..700, &"line#{String.pad_leading(to_string(&1), 6, "0")}")
      big_content = Enum.join(lines, "\n") <> "\n"
      File.write!(Path.join(completed.worktree_path, "big_file.txt"), big_content)
      {_, 0} = System.cmd("git", ["add", "."], cd: completed.worktree_path)

      {_, 0} =
        System.cmd("git", ["commit", "-q", "-m", "big commit"], cd: completed.worktree_path)

      TelegramPoller.handle_update(callback_update("jobdiff:#{job.id}"), state)

      assert_receive {:telegram_chat_action, @chat_id, "upload_document"}

      messages = collect_telegram_sends()
      assert length(messages) > 1
      assert Enum.all?(messages, &(byte_size(&1) <= 4096))
      # Order, not chunk boundaries, is what matters: `Telegram.chunk/2`
      # decides paragraph/line packing on its own, so assert the FIRST line
      # appears strictly before the LAST line once every chunk is stitched
      # back together in receive order - proving nothing was reordered or
      # dropped by the chunking/sending itself.
      full_text = Enum.join(messages)
      {first_idx, _} = :binary.match(full_text, "line000001")
      {last_idx, _} = :binary.match(full_text, "line000700")
      assert first_idx < last_idx
    end

    test "Show diff fires a typing/upload indicator before the diff is prepared", %{
      state: state,
      store: store
    } do
      TelegramPoller.handle_update(text_message("/run trainer fix the widget"), state)
      assert_receive {:telegram_send, _starting}
      assert [job] = JobStore.list(store)
      wait_for_status(store, job.id, :completed)

      TelegramPoller.handle_update(callback_update("jobdiff:#{job.id}"), state)

      assert_receive {:telegram_chat_action, @chat_id, "upload_document"}
      assert_receive {:telegram_send, _diff_text}
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

      assert_receive {:telegram_chat_action, @chat_id, "upload_document"}
      assert_receive {:telegram_send, output_text}
      assert output_text =~ "boom: something broke"
    end

    # Story #241: chunking replaces the old silent-truncation behavior for
    # Show output too, same as Show diff above.
    test "Show output longer than Telegram's limit arrives as multiple ordered, size-bounded messages",
         %{state: state, store: store, tmp_dir: tmp_dir} do
      huge_error =
        Enum.map_join(1..700, " ", &"errline#{String.pad_leading(to_string(&1), 6, "0")}")

      script = write_failing_fixture_engine_with_long_error(tmp_dir, huge_error)

      state = %{
        state
        | job_launch_opts: Keyword.put(state.job_launch_opts, :engine_opts, script: script)
      }

      TelegramPoller.handle_update(text_message("/run trainer break something"), state)
      assert_receive {:telegram_send, _starting}
      assert [job] = JobStore.list(store)
      wait_for_status(store, job.id, :failed)

      assert_receive {:telegram_edit_buttons, _message_id, _text, _buttons}

      TelegramPoller.handle_update(callback_update("jobshowoutput:#{job.id}"), state)

      messages = collect_telegram_sends()
      assert length(messages) > 1
      assert Enum.all?(messages, &(byte_size(&1) <= 4096))
      full_text = Enum.join(messages)
      {first_idx, _} = :binary.match(full_text, "errline000001")
      {last_idx, _} = :binary.match(full_text, "errline000700")
      assert first_idx < last_idx
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

      assert_receive {:watch_completed, ^job_id, transcript}, 5_000

      {:noreply, final_state} =
        TelegramPoller.handle_info({:watch_completed, job_id, transcript}, new_state)

      refute Map.has_key?(final_state.watches, job_id)
      assert_receive {:telegram_edit, ^transcript_message_id, final_text}
      assert final_text =~ "Read"
      assert final_text =~ "foo\\.ex"

      wait_for_status(store, job_id, :completed)
    end

    test "watching an already-terminal job whose transcript was already discarded gets the honest 'gone' reply",
         %{state: state, store: store, transcript: transcript} do
      TelegramPoller.handle_update(text_message("/run trainer fix the widget"), state)
      assert_receive {:telegram_send, _starting}
      assert [job] = JobStore.list(store)
      wait_for_status(store, job.id, :completed)
      wait_for_transcript_discard(transcript, job.id)

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

  # Convention check (story #241): every `state.telegram` call in the
  # job/watch paths must go through a retry-safe wrapper, never the raw
  # send/edit. A source-text regex is a deliberately blunt instrument, but
  # it catches a future call site sneaking in `state.telegram.send_message(`
  # (or an edit/buttons/markup equivalent) unnoticed - the class of
  # regression example-based tests on individual handlers can't rule out.
  test "no raw (non-retry) state.telegram send/edit calls remain in the job/watch paths" do
    source =
      File.read!(Path.join([__DIR__, "..", "..", "lib", "claude_notify", "telegram_poller.ex"]))

    raw_call_patterns = [
      ~r/state\.telegram\.send_message\(/,
      ~r/state\.telegram\.send_with_buttons\(/,
      ~r/state\.telegram\.edit_message_text\(/,
      ~r/state\.telegram\.edit_message_text_with_buttons\(/,
      ~r/state\.telegram\.edit_message_reply_markup\(/
    ]

    for pattern <- raw_call_patterns do
      refute source =~ pattern,
             "found a raw (non-retry) state.telegram call matching #{inspect(pattern)} - " <>
               "job/watch paths must use the _with_retry/_retry wrapper instead"
    end
  end
end
