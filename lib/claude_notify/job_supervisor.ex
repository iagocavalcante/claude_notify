defmodule ClaudeNotify.JobSupervisor do
  @moduledoc """
  Supervises one `ClaudeNotify.JobRunner` per running job, and enforces the
  concurrency cap (`:claude_notify, :job_concurrency`, default 3) - job-start
  requests beyond the cap wait in a FIFO queue and launch as soon as a
  running slot frees up.

  This module defines two collaborating processes, both meant to be started
  under `ClaudeNotify.Application`'s supervision tree:

    * `ClaudeNotify.JobSupervisor` itself - a plain `DynamicSupervisor`
      (`:one_for_one`) that owns the `JobRunner` processes. Pure supervision,
      no queueing logic: `JobRunner` is `restart: :temporary`, so a crashing
      or finished runner is simply gone, never restarted, and never affects
      any other runner under this strategy.
    * `ClaudeNotify.JobSupervisor.Dispatcher` - the single serialization
      point for "is there a free slot right now". A GenServer, because the
      cap check and the start-or-enqueue decision have to happen atomically
      across concurrent `start_job/2` requests - a set of plain functions
      racing on `DynamicSupervisor.which_children/1` could not enforce the
      cap correctly.

  Call `ClaudeNotify.JobSupervisor.start_job/2` to launch a job; do not call
  `DynamicSupervisor.start_child/2` on this module directly, since that
  bypasses the concurrency cap entirely.
  """

  use DynamicSupervisor

  alias ClaudeNotify.JobSupervisor.Dispatcher

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Requests that `job` (a `ClaudeNotify.JobStore.Job` in `:queued` status) be
  started. Starts it immediately if a concurrency slot is free, or enqueues
  it to start as soon as one is.

  Options:

    * `:dispatcher` - the Dispatcher process to call, defaults to
      `ClaudeNotify.JobSupervisor.Dispatcher`.
    * `:job_store`, `:engine_module`, `:project_registry`, `:slug`,
      `:engine_opts`, `:resume_session_id`, `:notifier` - forwarded to the
      Dispatcher; see its moduledoc.
  """
  def start_job(job, opts \\ []) do
    dispatcher = Keyword.get(opts, :dispatcher, Dispatcher)
    Dispatcher.start_job(dispatcher, job, opts)
  end

  @doc """
  Stops `job_id`'s runner process, if one is currently alive under this
  supervisor. Does not touch `ClaudeNotify.JobStore` - callers own the
  status transition (see `ClaudeNotify.TelegramPoller`'s `/cancel` handler,
  which drives the job to `:discarded` in the store itself and calls this
  only to actually terminate the underlying engine process).

  Returns `:stopped` if a live runner was found and terminated, or
  `:not_found` if no runner is currently running for that job id (e.g. the
  job was still `:queued`, or had already finished on its own).

  Options:

    * `:dynamic_supervisor` - defaults to `ClaudeNotify.JobSupervisor`.
  """
  def stop_job(job_id, opts \\ []) do
    dynamic_supervisor = Keyword.get(opts, :dynamic_supervisor, __MODULE__)

    case find_runner(dynamic_supervisor, job_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(dynamic_supervisor, pid)
        :stopped

      :not_found ->
        :not_found
    end
  end

  # Scans this supervisor's children for the one JobRunner driving `job_id`.
  # There's no registry keyed by job id (yet) - which_children/1 plus a tiny
  # per-child GenServer.call is the simplest mechanism the current code
  # supports for a supervisor that, at any moment, holds at most a handful
  # of running jobs (the concurrency cap defaults to 3).
  defp find_runner(dynamic_supervisor, job_id) do
    dynamic_supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(:not_found, fn
      {_, pid, :worker, _} when is_pid(pid) ->
        if runner_job_id(pid) == job_id, do: {:ok, pid}

      _ ->
        nil
    end)
  end

  # A runner can finish (and stop) between which_children/1 listing it and
  # this call - treated the same as "not this job's runner", not a crash.
  defp runner_job_id(pid) do
    ClaudeNotify.JobRunner.job_id(pid)
  catch
    :exit, _ -> nil
  end

  defmodule Dispatcher do
    @moduledoc """
    Owns the concurrency-cap and FIFO queue decision for `JobSupervisor` -
    see the parent moduledoc for why this needs to be a process at all.

    ## Project resolution

    The Dispatcher resolves every job through `ClaudeNotify.ProjectScope`
    before constructing its runner. Production uses the supervised canonical
    registry snapshot; a caller can pass `opts[:project_registry]` to resolve
    through a fresh or test-specific registry. `JobRunner` receives both the
    registered repository root and the resolved scope, and never derives
    identity from a worktree basename.

    ## Status transitions

    This Dispatcher owns the `:queued -> :running` transition, performed
    synchronously the moment a launch attempt begins (whether or not the
    launch actually succeeds afterwards) - `JobRunner` assumes the job it's
    handed is already `:running` and only ever drives the terminal
    `:running -> :failed` / `:running -> :completed` transitions. If the
    project can't be resolved, the engine is unsupported, or the runner
    fails to start, this Dispatcher drives `:running -> :failed` itself,
    since `JobRunner` never got a chance to.
    """

    use GenServer
    require Logger

    alias ClaudeNotify.{JobStore, JobRunner, ProjectScope}

    defstruct running: %{}, queue: :queue.new(), cap: 3, dynamic_supervisor: nil

    # -- Client API --

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
    end

    def start_job(pid \\ __MODULE__, job, opts \\ []) do
      GenServer.call(pid, {:start_job, job, opts})
    end

    @doc "Test/introspection helper: how many launch requests are currently queued."
    def queue_length(pid \\ __MODULE__) do
      GenServer.call(pid, :queue_length)
    end

    @doc "Test/introspection helper: how many jobs are currently occupying a concurrency slot."
    def running_count(pid \\ __MODULE__) do
      GenServer.call(pid, :running_count)
    end

    # -- Server callbacks --

    @impl true
    def init(opts) do
      cap = Keyword.get(opts, :cap, Application.get_env(:claude_notify, :job_concurrency, 3))
      dynamic_supervisor = Keyword.get(opts, :dynamic_supervisor, ClaudeNotify.JobSupervisor)
      {:ok, %__MODULE__{cap: cap, dynamic_supervisor: dynamic_supervisor}}
    end

    @impl true
    def handle_call({:start_job, job, opts}, _from, state) do
      if map_size(state.running) < state.cap do
        {:reply, :started, launch(job, opts, state)}
      else
        {:reply, :queued, %{state | queue: :queue.in({job, opts}, state.queue)}}
      end
    end

    @impl true
    def handle_call(:queue_length, _from, state) do
      {:reply, :queue.len(state.queue), state}
    end

    @impl true
    def handle_call(:running_count, _from, state) do
      {:reply, map_size(state.running), state}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
      state = %{state | running: Map.delete(state.running, ref)}
      {:noreply, dequeue(state)}
    end

    defp dequeue(state) do
      if map_size(state.running) < state.cap do
        case :queue.out(state.queue) do
          {{:value, {job, opts}}, rest} -> dequeue(launch(job, opts, %{state | queue: rest}))
          {:empty, _rest} -> state
        end
      else
        state
      end
    end

    defp launch(job, opts, state) do
      job_store = Keyword.get(opts, :job_store, JobStore)

      case JobStore.update_status(job_store, job.id, :running, %{}) do
        {:ok, _job} ->
          refresh_dashboard()

          case resolve_and_start(job, opts, job_store, state) do
            {:ok, new_state} ->
              new_state

            {:error, reason} ->
              Logger.error(
                "JobSupervisor: job #{job.id} could not be started: #{inspect(reason)}"
              )

              JobStore.update_status(job_store, job.id, :failed, %{})
              refresh_dashboard()
              state
          end

        {:error, reason} ->
          Logger.error(
            "JobSupervisor: job #{job.id} could not transition to :running: #{inspect(reason)}"
          )

          state
      end
    end

    defp resolve_and_start(job, opts, job_store, state) do
      scope_result =
        case Keyword.fetch(opts, :project_registry) do
          {:ok, registry} -> ProjectScope.for_project(registry, job.project)
          :error -> ProjectScope.for_project(job.project)
        end

      with {:ok, engine} <- resolve_engine(opts, job),
           {:ok, scope} <- scope_result,
           child_spec = job_runner_child_spec(job, engine, scope, opts, job_store),
           {:ok, pid} <- DynamicSupervisor.start_child(state.dynamic_supervisor, child_spec) do
        ref = Process.monitor(pid)
        {:ok, %{state | running: Map.put(state.running, ref, job.id)}}
      end
    end

    defp job_runner_child_spec(job, engine, scope, opts, job_store) do
      {JobRunner,
       job_id: job.id,
       engine: engine,
       engine_name: job.engine,
       repo_path: scope.repo_root,
       project_scope: scope,
       prompt: job.prompt,
       job_store: job_store,
       slug: Keyword.get(opts, :slug, "run"),
       engine_opts: Keyword.get(opts, :engine_opts, []),
       resume_session_id: Keyword.get(opts, :resume_session_id),
       notifier: Keyword.get(opts, :notifier, fn _event -> :ok end)}
    end

    defp resolve_engine(opts, job) do
      case Keyword.fetch(opts, :engine_module) do
        {:ok, module} -> {:ok, module}
        :error -> engine_for_name(job.engine)
      end
    end

    defp engine_for_name("claude"), do: {:ok, ClaudeNotify.Engine.Claude}
    defp engine_for_name("codex"), do: {:ok, ClaudeNotify.Engine.Codex}
    defp engine_for_name(other), do: {:error, {:unsupported_engine, other}}

    defp refresh_dashboard do
      if Process.whereis(ClaudeNotify.Dashboard), do: ClaudeNotify.Dashboard.refresh()
    end
  end
end
