defmodule ClaudeNotify.JobRunner do
  @moduledoc """
  Owns one job's engine CLI process end to end: creates the job's isolated
  worktree, spawns the engine as a `Port` inside it, parses its stdout into
  internal events, and drives `ClaudeNotify.JobStore` from `:running` to
  `:completed` or `:failed`.

  One `JobRunner` per job, supervised by `ClaudeNotify.JobSupervisor` under
  `:one_for_one` with `restart: :temporary` - jobs are one-shot, so a
  finished (or crashed) runner is never restarted, and a crashing engine
  process fails only its own job without touching any other job's runner.

  `JobRunner` expects the job to already be in `:running` status by the time
  it starts (see `ClaudeNotify.JobSupervisor.Dispatcher`, which owns the
  `:queued -> :running` transition as part of its concurrency-cap decision).
  From here `JobRunner` only ever drives the terminal `:running -> :failed`
  or `:running -> :completed` transitions, plus non-status field updates
  (`worktree_path`, `branch`, `engine_session_id`) via `JobStore.update/3`.

  Deliberately does not tear down the worktree on completion - the commit it
  holds is the input to a later PR-creation story.

  ## Progress/completion hook (`opts[:notifier]`)

  `opts[:notifier]` is an optional 1-arity function called with:

    * `{:progress, job_id, %{action_count:, files_touched:, current_tool:,
      current_detail:}}` on every `:tool_use` event - the same shape
      `ClaudeNotify.ActivityTracker`/`ClaudeNotify.MessageFormatter.activity_message/1`
      already use for terminal sessions, so a caller can reuse that
      formatter as-is.
    * `{:completed, job_id, %{status: :completed | :failed, summary:}}` once,
      right after the job's terminal `JobStore` transition actually
      succeeds (a transition that's rejected - e.g. the job was already
      `:discarded` by a racing `/cancel` - is not reported here, since
      nothing about the job's real outcome changed).

  This module only aggregates the raw counters/labels and calls the
  notifier with them - it does not format any Telegram text itself (see
  `ClaudeNotify.TelegramPoller`, the only current caller, for the
  formatting). Defaults to a no-op so every other caller (and every
  existing test) is unaffected.

  A failed job's `error_tail` (the engine's own reported error message, or
  - if the engine crashed before reporting one - the tail of its raw
  stdout) is persisted onto the `JobStore` record itself via the same
  `update_status/4` call that drives `:running -> :failed`, rather than
  being carried only in the transient notifier event: `:completed`'s
  `summary` field is not retained anywhere after the notifier call returns,
  so a later action against the job (e.g. a Telegram button pressed after
  this process has already exited) needs the error text to live in
  `JobStore`, not in this process's memory.

  ## Resuming (`opts[:resume_session_id]`)

  When `opts[:resume_session_id]` is set, `launch_engine/2` calls
  `engine.resume_command/3` instead of `engine.build_command/2`, so the
  engine CLI is told to continue an earlier conversation. This job still
  gets its own brand-new worktree cut from the repo's current default
  branch (see `create_worktree/1`), same as any other job - it does NOT
  check out the original job's branch. That's a real limitation: the
  engine's own memory of the earlier turn may reference files that only
  exist on the *original* job's branch, not on this fresh one. It's an
  acceptable starting point only because the job rules already require the
  engine to commit and leave its worktree clean before finishing, so in the
  common case there's nothing left uncommitted to lose - but a resumed run
  that expects to see uncommitted state from its earlier turn will not find
  it here. See `ClaudeNotify.TelegramPoller`'s reply-to-job handling, which
  is the only current caller of this option.
  """

  use GenServer, restart: :temporary
  require Logger

  alias ClaudeNotify.{JobStore, WorktreeManager}

  # Bounded tail of raw engine stdout lines, kept regardless of whether they
  # parsed into a recognized event - the only source for a failed job's
  # error_tail when the engine crashes before emitting any structured
  # result/error event of its own. Small on purpose: this is a fallback for
  # a Telegram message, not a log.
  @max_raw_lines 20

  defstruct [
    :job_id,
    :engine,
    :repo_path,
    :prompt,
    :job_store,
    :slug,
    :worktree,
    :port,
    :session_id,
    :resume_session_id,
    :last_summary,
    engine_opts: [],
    buffer: "",
    finalized: false,
    notifier: nil,
    action_count: 0,
    files_touched: MapSet.new(),
    current_tool: nil,
    current_detail: nil,
    raw_lines: []
  ]

  @job_rules """
  You are operating inside an isolated git worktree created solely for this job. Follow these rules:
  - Stay inside this worktree. Never touch any other checkout of this repository.
  - When your work is done, commit it with a clear message and leave the tree clean.
  - Never push, and never open a pull request. Committing locally is the end of this job.

  """

  # -- Client API --

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Prepends the job rules (worktree isolation, commit-at-end, no push) to `prompt`."
  def wrap_prompt(prompt), do: @job_rules <> prompt

  @doc "Test/introspection helper: the job id this runner is driving."
  def job_id(pid), do: GenServer.call(pid, :job_id)

  # -- Server callbacks --

  @impl true
  def init(opts) do
    state = %__MODULE__{
      job_id: Keyword.fetch!(opts, :job_id),
      engine: Keyword.fetch!(opts, :engine),
      repo_path: Keyword.fetch!(opts, :repo_path),
      prompt: Keyword.fetch!(opts, :prompt),
      job_store: Keyword.get(opts, :job_store, JobStore),
      slug: Keyword.get(opts, :slug, "run"),
      engine_opts: Keyword.get(opts, :engine_opts, []),
      resume_session_id: Keyword.get(opts, :resume_session_id),
      notifier: Keyword.get(opts, :notifier, fn _event -> :ok end)
    }

    {:ok, state, {:continue, :launch}}
  end

  @impl true
  def handle_call(:job_id, _from, state) do
    {:reply, state.job_id, state}
  end

  @impl true
  def handle_continue(:launch, state) do
    with {:ok, worktree} <- create_worktree(state),
         {:ok, _job} <-
           JobStore.update(state.job_store, state.job_id, %{
             worktree_path: worktree.path,
             branch: worktree.branch
           }),
         {:ok, port} <- launch_engine(state, worktree) do
      {:noreply, %{state | worktree: worktree, port: port}}
    else
      {:error, reason} ->
        Logger.error("JobRunner: job #{state.job_id} failed to launch: #{inspect(reason)}")
        fail_job(state)
        {:stop, :normal, %{state | finalized: true}}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {lines, remainder} = extract_lines(state.buffer <> data)

    new_state =
      lines
      |> Enum.reduce(state, &process_line/2)
      |> append_raw_lines(lines)

    {:noreply, %{new_state | buffer: remainder}}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    final_status = if status == 0, do: :completed, else: :failed
    extras = terminal_extras(state, final_status)

    case JobStore.update_status(state.job_store, state.job_id, final_status, extras) do
      {:ok, _job} -> notify_completed(state, final_status)
      {:error, _reason} -> :ok
    end

    {:stop, :normal, %{state | finalized: true}}
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{finalized: true}), do: :ok

  def terminate(_reason, state) do
    # Safety net: something crashed before the normal exit_status path could
    # finalize the job (e.g. an uncaught exception in a callback above).
    # The job is assumed to already be :running - see moduledoc.
    fail_job(state)
    :ok
  end

  # -- Launch --

  defp create_worktree(state) do
    WorktreeManager.create(state.repo_path, to_string(state.job_id), state.slug)
  end

  defp launch_engine(state, worktree) do
    wrapped_prompt = wrap_prompt(state.prompt)
    engine_opts = Keyword.put(state.engine_opts, :cwd, worktree.path)

    {cmd, args} =
      if state.resume_session_id do
        state.engine.resume_command(state.resume_session_id, wrapped_prompt, engine_opts)
      else
        state.engine.build_command(wrapped_prompt, engine_opts)
      end

    open_port(cmd, args, worktree.path)
  end

  defp open_port(cmd, args, cwd) do
    case System.find_executable(cmd) do
      nil ->
        {:error, {:executable_not_found, cmd}}

      executable ->
        try do
          port =
            Port.open({:spawn_executable, executable}, [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: args,
              cd: cwd
            ])

          {:ok, port}
        rescue
          error -> {:error, {:port_open_failed, error}}
        end
    end
  end

  defp fail_job(state) do
    extras = terminal_extras(state, :failed)

    case JobStore.update_status(state.job_store, state.job_id, :failed, extras) do
      {:ok, _job} -> notify_completed(state, :failed)
      {:error, _reason} -> :ok
    end
  end

  # `:error_tail` is only meaningful for a failed job - prefer the engine's
  # own reported error/result message (`last_summary`); fall back to the
  # raw stdout tail only if the engine crashed before reporting one at all
  # (or never got far enough to - e.g. `create_worktree/1` itself failing).
  defp terminal_extras(state, :failed) do
    %{engine_session_id: state.session_id, error_tail: state.last_summary || raw_tail(state)}
  end

  defp terminal_extras(state, :completed) do
    %{engine_session_id: state.session_id}
  end

  defp raw_tail(%{raw_lines: []}), do: nil
  defp raw_tail(%{raw_lines: lines}), do: Enum.join(lines, "\n")

  defp append_raw_lines(state, []), do: state

  defp append_raw_lines(state, lines) do
    updated = (state.raw_lines ++ lines) |> Enum.take(-@max_raw_lines)
    %{state | raw_lines: updated}
  end

  defp notify_progress(state) do
    state.notifier.({:progress, state.job_id, progress_snapshot(state)})
    state
  end

  defp notify_completed(state, status) do
    state.notifier.({:completed, state.job_id, %{status: status, summary: state.last_summary}})
  end

  defp progress_snapshot(state) do
    %{
      action_count: state.action_count,
      files_touched: state.files_touched,
      current_tool: state.current_tool,
      current_detail: state.current_detail
    }
  end

  # -- Stdout parsing --

  # Buffers up to the last newline: `data` can split a JSON line across
  # multiple Port messages (large tool outputs), so only text up to the
  # final "\n" is guaranteed to hold complete lines.
  defp extract_lines(buffer) do
    parts = String.split(buffer, "\n")
    {complete, [remainder]} = Enum.split(parts, -1)
    {complete, remainder}
  end

  defp process_line("", state), do: state

  defp process_line(line, state) do
    case state.engine.parse_event(line) do
      {:ok, {:result, %{session_id: session_id, summary: summary} = result}} ->
        Logger.info("JobRunner: job #{state.job_id} result: #{inspect(result)}")

        state
        |> maybe_store_session_id(session_id)
        |> Map.put(:last_summary, summary || state.last_summary)

      {:ok, {:session, session_id}} ->
        maybe_store_session_id(state, session_id)

      {:ok, {:tool_use, detail}} ->
        state
        |> track_progress(detail)
        |> notify_progress()

      {:ok, {:text, _text}} ->
        state

      :ignore ->
        state

      {:error, reason} ->
        Logger.warning(
          "JobRunner: job #{state.job_id} could not parse an engine line: #{inspect(reason)}"
        )

        state
    end
  end

  defp maybe_store_session_id(state, nil), do: state

  defp maybe_store_session_id(state, session_id) do
    JobStore.update(state.job_store, state.job_id, %{engine_session_id: session_id})
    %{state | session_id: session_id}
  end

  # -- Progress tracking (for opts[:notifier]) --

  defp track_progress(state, %{name: name, input: input}) do
    detail = tool_detail(name, input)
    file = touched_file(name, input)

    %{
      state
      | action_count: state.action_count + 1,
        current_tool: name,
        current_detail: detail,
        files_touched:
          if(file, do: MapSet.put(state.files_touched, file), else: state.files_touched)
    }
  end

  defp tool_detail(name, input) when name in ["Read", "Write", "Edit"] and is_map(input),
    do: Map.get(input, "file_path")

  defp tool_detail("Bash", input) when is_map(input), do: Map.get(input, "command")

  defp tool_detail(name, input) when name in ["Glob", "Grep"] and is_map(input),
    do: Map.get(input, "pattern")

  defp tool_detail(_name, _input), do: nil

  defp touched_file(name, input) when name in ["Read", "Write", "Edit"] and is_map(input) do
    case Map.get(input, "file_path") do
      path when is_binary(path) -> Path.basename(path)
      _ -> nil
    end
  end

  defp touched_file(_name, _input), do: nil
end
