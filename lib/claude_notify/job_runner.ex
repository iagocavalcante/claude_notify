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
    engine_opts: [],
    buffer: "",
    finalized: false
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
      resume_session_id: Keyword.get(opts, :resume_session_id)
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
    new_state = Enum.reduce(lines, state, &process_line/2)
    {:noreply, %{new_state | buffer: remainder}}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    final_status = if status == 0, do: :completed, else: :failed

    JobStore.update_status(state.job_store, state.job_id, final_status, %{
      engine_session_id: state.session_id
    })

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
    JobStore.update_status(state.job_store, state.job_id, :failed, %{
      engine_session_id: state.session_id
    })
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
      {:ok, {:result, %{session_id: session_id} = result}} ->
        Logger.info("JobRunner: job #{state.job_id} result: #{inspect(result)}")
        maybe_store_session_id(state, session_id)

      {:ok, {:session, session_id}} ->
        maybe_store_session_id(state, session_id)

      {:ok, {:tool_use, _detail}} ->
        state

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
end
