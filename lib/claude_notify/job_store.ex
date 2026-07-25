defmodule ClaudeNotify.JobStore do
  @moduledoc """
  Persistent store for dispatcher jobs (one job = one worktree + engine run).

  Backed by a `:dets` table so job state (and the worktree/branch it belongs
  to) survives an app restart. All reads and mutations are serialized through
  this GenServer so that status transitions can be validated atomically.

  Does not supervise the underlying job (see the JobRunner story) and does
  not format Telegram messages — this module only owns job CRUD and status.
  """

  use GenServer

  @valid_statuses [:queued, :running, :awaiting_input, :completed, :failed, :discarded]

  @transitions %{
    queued: MapSet.new([:running, :discarded]),
    running: MapSet.new([:awaiting_input, :completed, :failed, :discarded]),
    awaiting_input: MapSet.new([:running, :completed, :failed, :discarded]),
    completed: MapSet.new([]),
    failed: MapSet.new([]),
    discarded: MapSet.new([])
  }

  defmodule Job do
    @moduledoc "A single dispatcher job record."

    defstruct [
      :id,
      :engine,
      :project,
      :prompt,
      :worktree_path,
      :branch,
      :engine_session_id,
      status: :queued,
      telegram_message_ids: [],
      inserted_at: nil,
      updated_at: nil
    ]
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  def create(pid \\ __MODULE__, attrs) do
    GenServer.call(pid, {:create, attrs})
  end

  def get(pid \\ __MODULE__, id) do
    GenServer.call(pid, {:get, id})
  end

  def update(pid \\ __MODULE__, id, attrs) do
    GenServer.call(pid, {:update, id, attrs})
  end

  def update_status(pid \\ __MODULE__, id, status, extras \\ %{}) do
    GenServer.call(pid, {:update_status, id, status, extras})
  end

  def list(pid \\ __MODULE__, filters \\ []) do
    GenServer.call(pid, {:list, filters})
  end

  def clear(pid \\ __MODULE__) do
    GenServer.call(pid, :clear)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    table = opts[:name] || __MODULE__
    path = opts[:path] || default_path()

    File.mkdir_p!(Path.dirname(path))
    {:ok, table} = :dets.open_file(table, file: String.to_charlist(path), type: :set)

    next_id = :dets.foldl(fn {id, _job}, acc -> max(id, acc) end, 0, table) + 1

    {:ok, %{table: table, next_id: next_id}}
  end

  @impl true
  def terminate(_reason, state) do
    :dets.close(state.table)
    :ok
  end

  @impl true
  def handle_call({:create, attrs}, _from, state) do
    now = System.system_time(:second)
    id = state.next_id

    job = %Job{
      id: id,
      engine: attrs[:engine],
      project: attrs[:project],
      prompt: attrs[:prompt],
      worktree_path: attrs[:worktree_path],
      branch: attrs[:branch],
      engine_session_id: attrs[:engine_session_id],
      status: :queued,
      telegram_message_ids: attrs[:telegram_message_ids] || [],
      inserted_at: now,
      updated_at: now
    }

    :dets.insert(state.table, {id, job})
    {:reply, {:ok, job}, %{state | next_id: id + 1}}
  end

  @impl true
  def handle_call({:get, id}, _from, state) do
    {:reply, fetch(state.table, id), state}
  end

  @impl true
  def handle_call({:update, id, attrs}, _from, state) do
    cond do
      Map.has_key?(attrs, :status) ->
        {:reply, {:error, :use_update_status}, state}

      fetch(state.table, id) == nil ->
        {:reply, {:error, :not_found}, state}

      true ->
        job = fetch(state.table, id)
        updated = struct!(job, Map.put(attrs, :updated_at, System.system_time(:second)))
        :dets.insert(state.table, {id, updated})
        {:reply, {:ok, updated}, state}
    end
  end

  @impl true
  def handle_call({:update_status, id, status, extras}, _from, state) do
    cond do
      Map.has_key?(extras, :status) ->
        {:reply, {:error, :use_update_status}, state}

      status not in @valid_statuses ->
        {:reply, {:error, {:invalid_status, status}}, state}

      fetch(state.table, id) == nil ->
        {:reply, {:error, :not_found}, state}

      true ->
        job = fetch(state.table, id)
        allowed = Map.fetch!(@transitions, job.status)

        if MapSet.member?(allowed, status) do
          updated =
            job
            |> struct!(extras)
            |> Map.put(:status, status)
            |> Map.put(:updated_at, System.system_time(:second))

          :dets.insert(state.table, {id, updated})
          {:reply, {:ok, updated}, state}
        else
          {:reply, {:error, {:invalid_transition, job.status, status}}, state}
        end
    end
  end

  @impl true
  def handle_call({:list, filters}, _from, state) do
    jobs =
      state.table
      |> all_jobs()
      |> maybe_filter_by_status(filters[:status])
      |> Enum.sort_by(& &1.id)

    {:reply, jobs, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :dets.delete_all_objects(state.table)
    {:reply, :ok, %{state | next_id: 1}}
  end

  defp fetch(table, id) do
    case :dets.lookup(table, id) do
      [{^id, job}] -> job
      [] -> nil
    end
  end

  defp all_jobs(table) do
    :dets.foldl(fn {_id, job}, acc -> [job | acc] end, [], table)
  end

  defp maybe_filter_by_status(jobs, nil), do: jobs
  defp maybe_filter_by_status(jobs, status), do: Enum.filter(jobs, &(&1.status == status))

  defp default_path do
    Application.get_env(
      :claude_notify,
      :job_store_path,
      Path.join([System.user_home!(), ".claude_notify", "job_store.dat"])
    )
  end
end
