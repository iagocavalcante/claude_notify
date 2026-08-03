defmodule ClaudeNotify.SessionStore do
  use GenServer

  @stale_interval :timer.minutes(30)
  @stale_threshold :timer.hours(24)
  @tty_regex ~r|^/dev/ttys[0-9]+$|

  defstruct sessions: %{}, message_map: %{}, notification_text: %{}, path: nil

  # Client API

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def register_prompt(session_id, prompt, working_dir, opts \\ %{}) do
    GenServer.call(__MODULE__, {:register_prompt, session_id, prompt, working_dir, opts})
  end

  def register_stop(session_id, stop_reason) do
    GenServer.call(__MODULE__, {:register_stop, session_id, stop_reason})
  end

  def remove_session(session_id) do
    GenServer.call(__MODULE__, {:remove_session, session_id})
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

  def terminal_sessions do
    GenServer.call(__MODULE__, :terminal_sessions)
  end

  def set_prompt_message_id(session_id, message_id) do
    GenServer.call(__MODULE__, {:set_prompt_message_id, session_id, message_id})
  end

  def get_prompt_message_id(session_id) do
    case get_session(session_id) do
      %{prompt_message_id: mid} -> mid
      _ -> nil
    end
  end

  def register_message(message_id, session_id) do
    GenServer.cast(__MODULE__, {:register_message, message_id, session_id})
  end

  def lookup_session_by_message(message_id) do
    GenServer.call(__MODULE__, {:lookup_message, message_id})
  end

  @doc """
  Records the full notification text against a message_id, used by the
  See more button to expand truncated permission prompts back to full size.
  """
  def register_notification_text(message_id, full_text) do
    GenServer.cast(__MODULE__, {:register_notification_text, message_id, full_text})
  end

  def get_notification_text(message_id) do
    GenServer.call(__MODULE__, {:get_notification_text, message_id})
  end

  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    schedule_cleanup()
    path = opts[:path] || default_path()
    state = %{load(path) | path: path}
    persist(state)
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
    persist(new_state)
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
    persist(new_state)
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
        persist(new_state)
        {:reply, {:ok, session}, new_state}
    end
  end

  @impl true
  def handle_call({:register_stop, session_id, stop_reason}, _from, state) do
    now = System.system_time(:second)

    existing =
      Map.get(state.sessions, session_id) ||
        %{
          id: session_id,
          working_dir: "unknown",
          prompt_count: 0,
          first_prompt: nil,
          started_at: now,
          last_tool: nil,
          tty_path: nil,
          term_session_id: nil
        }

    # Claude Code's Stop hook marks the end of one assistant turn, not the
    # end of the terminal process. Keep the session addressable so /sessions,
    # /dashboard, and reply-to-session continue to work while Claude is idle.
    session =
      Map.merge(existing, %{
        status: :idle,
        stopped_at: now,
        stop_reason: stop_reason,
        last_activity: now
      })

    owned_mids =
      state.message_map
      |> Enum.filter(fn {_mid, sid} -> sid == session_id end)
      |> Enum.map(fn {mid, _sid} -> mid end)

    new_state = %{
      state
      | sessions: Map.put(state.sessions, session_id, session),
        # Old permission expansion bodies are no longer actionable after the
        # turn, but message routing remains valid for the idle session.
        notification_text: Map.drop(state.notification_text, owned_mids)
    }

    persist(new_state)
    {:reply, {:idle, session}, new_state}
  end

  @impl true
  def handle_call({:remove_session, session_id}, _from, state) do
    owned_mids =
      state.message_map
      |> Enum.filter(fn {_mid, sid} -> sid == session_id end)
      |> Enum.map(fn {mid, _sid} -> mid end)

    existed? = Map.has_key?(state.sessions, session_id)

    new_state = %{
      state
      | sessions: Map.delete(state.sessions, session_id),
        message_map: Map.drop(state.message_map, owned_mids),
        notification_text: Map.drop(state.notification_text, owned_mids)
    }

    persist(new_state)
    {:reply, if(existed?, do: :ok, else: :not_found), new_state}
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
  def handle_call(:terminal_sessions, _from, state) do
    {:reply, filter_terminal_sessions(state.sessions), state}
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
        persist(new_state)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:get_notification_text, message_id}, _from, state) do
    {:reply, Map.get(state.notification_text, message_id), state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    new_state = %__MODULE__{path: state.path}
    persist(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast({:register_message, message_id, session_id}, state) do
    new_state = %{state | message_map: Map.put(state.message_map, message_id, session_id)}
    persist(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:register_notification_text, message_id, full_text}, state) do
    new_state = %{
      state
      | notification_text: Map.put(state.notification_text, message_id, full_text)
    }

    persist(new_state)
    {:noreply, new_state}
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

    cleaned_notification_text =
      state.notification_text
      |> Map.take(Map.keys(cleaned_messages))

    schedule_cleanup()

    new_state = %{
      state
      | sessions: cleaned,
        message_map: cleaned_messages,
        notification_text: cleaned_notification_text
    }

    persist(new_state)
    {:noreply, new_state}
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

  defp persist(%{path: nil}), do: :ok

  defp persist(state) do
    data =
      :erlang.term_to_binary(%{
        sessions: state.sessions,
        message_map: state.message_map,
        notification_text: state.notification_text
      })

    tmp_path = state.path <> ".tmp"
    File.mkdir_p!(Path.dirname(state.path))
    File.write!(tmp_path, data)
    File.rename!(tmp_path, state.path)
    :ok
  end

  defp load(nil), do: %__MODULE__{}

  defp load(path) do
    with true <- File.exists?(path),
         {:ok, binary} <- File.read(path),
         {:ok, data} <- safe_decode(binary) do
      sessions = data |> Map.get(:sessions, %{}) |> filter_terminal_sessions()
      session_ids = Map.keys(sessions) |> MapSet.new()

      message_map =
        data
        |> Map.get(:message_map, %{})
        |> Enum.filter(fn {_mid, session_id} -> MapSet.member?(session_ids, session_id) end)
        |> Map.new()

      %__MODULE__{
        sessions: sessions,
        message_map: message_map,
        notification_text:
          data |> Map.get(:notification_text, %{}) |> Map.take(Map.keys(message_map))
      }
    else
      _ -> %__MODULE__{}
    end
  end

  defp safe_decode(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> :error
  end

  defp filter_terminal_sessions(sessions) do
    sessions
    |> Enum.filter(fn {session_id, session} ->
      session_id != "unknown" and valid_tty?(session[:tty_path])
    end)
    |> Map.new()
  end

  defp valid_tty?(tty_path) when is_binary(tty_path), do: Regex.match?(@tty_regex, tty_path)
  defp valid_tty?(_tty_path), do: false

  defp default_path do
    Application.get_env(
      :claude_notify,
      :session_store_path,
      Path.join([System.user_home!(), ".claude_notify", "session_store.dat"])
    )
  end
end
