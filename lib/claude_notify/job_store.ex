defmodule ClaudeNotify.JobStore do
  @moduledoc """
  Persistent store for dispatcher jobs (one job = one worktree + engine run).

  Job state (and the worktree/branch it belongs to) is written through to
  disk on every mutation, so it survives a process or app restart. All reads
  and mutations are serialized through this GenServer so that status
  transitions can be validated atomically.

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
      :error_tail,
      status: :queued,
      telegram_message_ids: [],
      inserted_at: nil,
      updated_at: nil
    ]
  end

  defstruct jobs: %{}, next_id: 1, path: nil

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
    path = opts[:path] || default_path()
    {:ok, %{load(path) | path: path}}
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

    new_state = %{state | jobs: Map.put(state.jobs, id, job), next_id: id + 1}
    persist(new_state)
    {:reply, {:ok, job}, new_state}
  end

  @impl true
  def handle_call({:get, id}, _from, state) do
    {:reply, Map.get(state.jobs, id), state}
  end

  @impl true
  def handle_call({:update, id, attrs}, _from, state) do
    cond do
      Map.has_key?(attrs, :status) ->
        {:reply, {:error, :use_update_status}, state}

      not Map.has_key?(state.jobs, id) ->
        {:reply, {:error, :not_found}, state}

      true ->
        job = state.jobs[id]
        updated = struct!(job, Map.put(attrs, :updated_at, System.system_time(:second)))
        new_state = %{state | jobs: Map.put(state.jobs, id, updated)}
        persist(new_state)
        {:reply, {:ok, updated}, new_state}
    end
  end

  @impl true
  def handle_call({:update_status, id, status, extras}, _from, state) do
    cond do
      Map.has_key?(extras, :status) ->
        {:reply, {:error, :use_update_status}, state}

      status not in @valid_statuses ->
        {:reply, {:error, {:invalid_status, status}}, state}

      not Map.has_key?(state.jobs, id) ->
        {:reply, {:error, :not_found}, state}

      true ->
        job = state.jobs[id]
        allowed = Map.fetch!(@transitions, job.status)

        if MapSet.member?(allowed, status) do
          updated =
            job
            |> struct!(extras)
            |> Map.put(:status, status)
            |> Map.put(:updated_at, System.system_time(:second))

          new_state = %{state | jobs: Map.put(state.jobs, id, updated)}
          persist(new_state)
          {:reply, {:ok, updated}, new_state}
        else
          {:reply, {:error, {:invalid_transition, job.status, status}}, state}
        end
    end
  end

  @impl true
  def handle_call({:list, filters}, _from, state) do
    jobs =
      state.jobs
      |> Map.values()
      |> maybe_filter_by_status(filters[:status])
      |> Enum.sort_by(& &1.id)

    {:reply, jobs, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    new_state = %{state | jobs: %{}, next_id: 1}
    persist(new_state)
    {:reply, :ok, new_state}
  end

  defp maybe_filter_by_status(jobs, nil), do: jobs
  defp maybe_filter_by_status(jobs, status), do: Enum.filter(jobs, &(&1.status == status))

  # Writes to a temp file and renames over the real path, so a crash mid-write
  # never leaves a partially-written store file behind.
  defp persist(state) do
    data = :erlang.term_to_binary(%{jobs: state.jobs, next_id: state.next_id})
    tmp_path = state.path <> ".tmp"

    File.mkdir_p!(Path.dirname(state.path))
    File.write!(tmp_path, data)
    File.rename!(tmp_path, state.path)
    :ok
  end

  defp load(path) do
    with true <- File.exists?(path),
         {:ok, binary} <- File.read(path),
         {:ok, %{jobs: jobs, next_id: next_id}} <- safe_decode(binary) do
      %__MODULE__{jobs: jobs, next_id: next_id}
    else
      _ -> %__MODULE__{}
    end
  end

  # :safe rejects data that would create new atoms, so a corrupted or
  # tampered store file can't be used to exhaust the atom table.
  defp safe_decode(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> :error
  end

  defp default_path do
    Application.get_env(
      :claude_notify,
      :job_store_path,
      Path.join([System.user_home!(), ".claude_notify", "job_store.dat"])
    )
  end
end
