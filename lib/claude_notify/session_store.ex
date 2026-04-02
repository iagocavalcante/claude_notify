defmodule ClaudeNotify.SessionStore do
  use GenServer

  @stale_interval :timer.minutes(30)
  @stale_threshold :timer.hours(2)

  defstruct sessions: %{}, message_map: %{}

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  def register_prompt(session_id, prompt, working_dir, opts \\ %{}) do
    GenServer.call(__MODULE__, {:register_prompt, session_id, prompt, working_dir, opts})
  end

  def register_stop(session_id, stop_reason) do
    GenServer.call(__MODULE__, {:register_stop, session_id, stop_reason})
  end

  def get_session(session_id) do
    GenServer.call(__MODULE__, {:get_session, session_id})
  end

  def update_session_metadata(session_id, working_dir, opts \\ %{}) do
    GenServer.call(__MODULE__, {:update_session_metadata, session_id, working_dir, opts})
  end

  def update_status(session_id, status, extras \\ %{}) do
    GenServer.call(__MODULE__, {:update_status, session_id, status, extras})
  end

  def all_sessions do
    GenServer.call(__MODULE__, :all_sessions)
  end

  def set_prompt_message_id(session_id, message_id) do
    GenServer.call(__MODULE__, {:set_prompt_message_id, session_id, message_id})
  end

  def register_message(message_id, session_id) do
    GenServer.cast(__MODULE__, {:register_message, message_id, session_id})
  end

  def lookup_session_by_message(message_id) do
    GenServer.call(__MODULE__, {:lookup_message, message_id})
  end

  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # Server callbacks

  @impl true
  def init(state) do
    schedule_cleanup()
    {:ok, state}
  end

  @impl true
  def handle_call({:register_prompt, session_id, prompt, working_dir, opts}, _from, state) do
    now = System.system_time(:second)

    {action, session} =
      case Map.get(state.sessions, session_id) do
        nil ->
          session = %{
            id: session_id,
            working_dir: working_dir,
            prompt_count: 1,
            first_prompt: prompt,
            started_at: now,
            last_activity: now,
            status: :active,
            last_tool: nil,
            tty_path: opts["tty_path"],
            term_session_id: opts["term_session_id"]
          }

          {:new_session, session}

        existing ->
          session =
            existing
            |> Map.merge(%{
              prompt_count: existing.prompt_count + 1,
              last_activity: now,
              status: :active
            })
            |> maybe_put(:working_dir, working_dir)
            |> maybe_update_tty(opts)

          {:prompt_update, session}
      end

    new_state = %{state | sessions: Map.put(state.sessions, session_id, session)}
    {:reply, {action, session}, new_state}
  end

  @impl true
  def handle_call({:update_session_metadata, session_id, working_dir, opts}, _from, state) do
    now = System.system_time(:second)

    {action, session} =
      case Map.get(state.sessions, session_id) do
        nil ->
          session = %{
            id: session_id,
            working_dir: working_dir,
            prompt_count: 0,
            first_prompt: nil,
            started_at: now,
            last_activity: now,
            status: :active,
            last_tool: nil,
            tty_path: opts["tty_path"],
            term_session_id: opts["term_session_id"]
          }

          {:new_session, maybe_update_tty(session, opts)}

        existing ->
          session =
            existing
            |> Map.merge(%{last_activity: now})
            |> maybe_put(:working_dir, working_dir)
            |> maybe_update_tty(opts)

          {:metadata_update, session}
      end

    new_state = %{state | sessions: Map.put(state.sessions, session_id, session)}
    {:reply, {action, session}, new_state}
  end

  @impl true
  def handle_call({:update_status, session_id, status, extras}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, :not_found, state}

      existing ->
        now = System.system_time(:second)

        session =
          existing
          |> Map.merge(%{status: status, last_activity: now})
          |> Map.merge(extras)

        new_state = %{state | sessions: Map.put(state.sessions, session_id, session)}
        {:reply, {:ok, session}, new_state}
    end
  end

  @impl true
  def handle_call({:register_stop, session_id, stop_reason}, _from, state) do
    now = System.system_time(:second)

    case Map.get(state.sessions, session_id) do
      nil ->
        session = %{
          id: session_id,
          working_dir: "unknown",
          prompt_count: 0,
          first_prompt: nil,
          started_at: now,
          last_activity: now,
          stopped_at: now,
          stop_reason: stop_reason
        }

        {:reply, {:stopped, session}, state}

      existing ->
        session =
          Map.merge(existing, %{
            stopped_at: now,
            stop_reason: stop_reason,
            last_activity: now
          })

        cleaned_messages =
          state.message_map
          |> Enum.reject(fn {_mid, sid} -> sid == session_id end)
          |> Map.new()

        new_state = %{
          state
          | sessions: Map.delete(state.sessions, session_id),
            message_map: cleaned_messages
        }

        {:reply, {:stopped, session}, new_state}
    end
  end

  @impl true
  def handle_call({:get_session, session_id}, _from, state) do
    {:reply, Map.get(state.sessions, session_id), state}
  end

  @impl true
  def handle_call(:all_sessions, _from, state) do
    {:reply, state.sessions, state}
  end

  @impl true
  def handle_call({:lookup_message, message_id}, _from, state) do
    {:reply, Map.get(state.message_map, message_id), state}
  end

  @impl true
  def handle_call({:set_prompt_message_id, session_id, message_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, :not_found, state}

      session ->
        updated = Map.put(session, :prompt_message_id, message_id)
        new_state = %{state | sessions: Map.put(state.sessions, session_id, updated)}
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    {:reply, :ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:register_message, message_id, session_id}, state) do
    {:noreply, %{state | message_map: Map.put(state.message_map, message_id, session_id)}}
  end

  @impl true
  def handle_info(:cleanup_stale, state) do
    now = System.system_time(:second)
    threshold = div(@stale_threshold, 1000)

    cleaned =
      state.sessions
      |> Enum.reject(fn {_id, session} -> now - session.last_activity > threshold end)
      |> Map.new()

    remaining_ids = MapSet.new(Map.keys(cleaned))

    cleaned_messages =
      state.message_map
      |> Enum.filter(fn {_mid, sid} -> MapSet.member?(remaining_ids, sid) end)
      |> Map.new()

    schedule_cleanup()
    {:noreply, %{state | sessions: cleaned, message_map: cleaned_messages}}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_stale, @stale_interval)
  end

  defp maybe_update_tty(session, opts) do
    session
    |> maybe_put(:tty_path, opts["tty_path"])
    |> maybe_put(:term_session_id, opts["term_session_id"])
    |> maybe_put(:transcript_path, opts["transcript_path"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, "unknown"), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
