defmodule ClaudeNotify.SessionStore do
  use GenServer

  @stale_interval :timer.minutes(30)
  @stale_threshold :timer.hours(24)
  @tty_regex ~r|^/dev/ttys[0-9]+$|

  defstruct sessions: %{},
            message_map: %{},
            notification_text: %{},
            bindings: %{},
            path: nil

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

  @doc "Persistently binds one Telegram chat to an open terminal session."
  def bind_chat(chat_id, session_id) do
    GenServer.call(__MODULE__, {:bind_chat, chat_id, session_id})
  end

  def unbind_chat(chat_id) do
    GenServer.call(__MODULE__, {:unbind_chat, chat_id})
  end

  def bound_session(chat_id) do
    GenServer.call(__MODULE__, {:bound_session, chat_id})
  end

  @doc "Marks a Telegram-authored prompt so its hook echo can reuse the inbound message."
  def mark_telegram_prompt(session_id, prompt, message_id)
      when is_binary(prompt) and is_integer(message_id) do
    GenServer.call(__MODULE__, {:mark_telegram_prompt, session_id, prompt, message_id})
  end

  def claim_telegram_prompt(session_id, prompt) when is_binary(prompt) do
    GenServer.call(__MODULE__, {:claim_telegram_prompt, session_id, prompt})
  end

  @doc "Stores a transcript byte checkpoint without adding chat history."
  def checkpoint_transcript(session_id, transcript_path, cursor)
      when is_binary(transcript_path) and is_integer(cursor) and cursor >= 0 do
    GenServer.call(__MODULE__, {:checkpoint_transcript, session_id, transcript_path, cursor})
  end

  @doc "Records newly observed assistant messages and advances the transcript cursor."
  def record_assistant_messages(session_id, transcript_path, cursor, messages)
      when is_integer(cursor) and cursor >= 0 and is_list(messages) do
    GenServer.call(
      __MODULE__,
      {:record_assistant_messages, session_id, transcript_path, cursor, messages}
    )
  end

  @doc "Returns the newest bounded normalized chat entries for a terminal session."
  def history(session_id, limit \\ 12) when is_integer(limit) and limit > 0 do
    GenServer.call(__MODULE__, {:history, session_id, limit})
  end

  def append_history(session_id, role, text)
      when role in [:user, :assistant, :question] and is_binary(text) do
    GenServer.call(__MODULE__, {:append_history, session_id, role, text})
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
            project_scope: opts["project_scope"],
            engine: normalize_engine(opts["engine"]),
            tty_path: opts["tty_path"],
            term_session_id: opts["term_session_id"],
            history: []
          }

          session =
            session
            |> maybe_update_tty(opts)
            |> Map.put(:last_assistant_fingerprint, nil)
            |> append_history_entry(:user, prompt)

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
            |> Map.put(:last_assistant_fingerprint, nil)
            |> append_history_entry(:user, prompt)

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
            project_scope: opts["project_scope"],
            engine: normalize_engine(opts["engine"]),
            tty_path: opts["tty_path"],
            term_session_id: opts["term_session_id"],
            history: []
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
          project_scope: nil,
          engine: "claude",
          tty_path: nil,
          term_session_id: nil,
          history: []
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

    remaining_bindings =
      state.bindings
      |> Enum.reject(fn {_chat_id, bound_session_id} -> bound_session_id == session_id end)
      |> Map.new()

    new_state = %{
      state
      | sessions: Map.delete(state.sessions, session_id),
        message_map: Map.drop(state.message_map, owned_mids),
        notification_text: Map.drop(state.notification_text, owned_mids),
        bindings: remaining_bindings
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
  def handle_call({:bind_chat, chat_id, session_id}, _from, state) do
    if Map.has_key?(state.sessions, session_id) do
      new_state = %{state | bindings: Map.put(state.bindings, chat_id, session_id)}
      persist(new_state)
      {:reply, :ok, new_state}
    else
      {:reply, :not_found, state}
    end
  end

  @impl true
  def handle_call({:unbind_chat, chat_id}, _from, state) do
    new_state = %{state | bindings: Map.delete(state.bindings, chat_id)}
    persist(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:bound_session, chat_id}, _from, state) do
    session_id = Map.get(state.bindings, chat_id)

    if session_id && Map.has_key?(state.sessions, session_id) do
      {:reply, session_id, state}
    else
      {:reply, nil, state}
    end
  end

  @impl true
  def handle_call({:mark_telegram_prompt, session_id, prompt, message_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, :not_found, state}

      session ->
        pending = %{
          text: normalize_prompt(prompt),
          message_id: message_id,
          at: System.system_time(:second)
        }

        updated =
          session
          |> Map.put(:pending_telegram_prompt, pending)
          |> Map.put(:prompt_message_id, message_id)

        new_state = %{
          state
          | sessions: Map.put(state.sessions, session_id, updated),
            message_map: Map.put(state.message_map, message_id, session_id)
        }

        persist(new_state)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:claim_telegram_prompt, session_id, prompt}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, :none, state}

      session ->
        now = System.system_time(:second)
        pending = session[:pending_telegram_prompt]
        normalized_prompt = normalize_prompt(prompt)

        {reply, updated} =
          case pending do
            %{text: text, message_id: message_id, at: at}
            when text == normalized_prompt and now - at <= 120 ->
              {{:ok, message_id}, Map.delete(session, :pending_telegram_prompt)}

            %{at: at} when now - at > 120 ->
              {:none, Map.delete(session, :pending_telegram_prompt)}

            _ ->
              {:none, session}
          end

        new_state = %{state | sessions: Map.put(state.sessions, session_id, updated)}
        persist(new_state)
        {:reply, reply, new_state}
    end
  end

  @impl true
  def handle_call(
        {:checkpoint_transcript, session_id, transcript_path, cursor},
        _from,
        state
      ) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, :not_found, state}

      session ->
        updated = put_transcript_cursor(session, transcript_path, cursor)
        new_state = %{state | sessions: Map.put(state.sessions, session_id, updated)}
        persist(new_state)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(
        {:record_assistant_messages, session_id, transcript_path, cursor, messages},
        _from,
        state
      ) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      session ->
        {updated, accepted} = append_new_assistant_messages(session, messages)
        updated = put_transcript_cursor(updated, transcript_path, cursor)
        new_state = %{state | sessions: Map.put(state.sessions, session_id, updated)}
        persist(new_state)
        {:reply, {:ok, accepted}, new_state}
    end
  end

  @impl true
  def handle_call({:history, session_id, limit}, _from, state) do
    history =
      case Map.get(state.sessions, session_id) do
        nil -> []
        session -> session |> Map.get(:history, []) |> Enum.take(-limit)
      end

    {:reply, history, state}
  end

  @impl true
  def handle_call({:append_history, session_id, role, text}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, :not_found, state}

      session ->
        updated = append_history_entry(session, role, text)
        new_state = %{state | sessions: Map.put(state.sessions, session_id, updated)}
        persist(new_state)
        {:reply, :ok, new_state}
    end
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

    cleaned_bindings =
      state.bindings
      |> Enum.filter(fn {_chat_id, session_id} -> MapSet.member?(remaining_ids, session_id) end)
      |> Map.new()

    schedule_cleanup()

    new_state = %{
      state
      | sessions: cleaned,
        message_map: cleaned_messages,
        notification_text: cleaned_notification_text,
        bindings: cleaned_bindings
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
    |> maybe_put_transcript_path(opts["transcript_path"])
    |> maybe_put(:project_scope, opts["project_scope"])
    |> maybe_put_engine(opts["engine"])
  end

  defp maybe_put_transcript_path(session, path) when path in [nil, "", "unknown"], do: session

  defp maybe_put_transcript_path(%{transcript_path: path} = session, path), do: session

  defp maybe_put_transcript_path(session, path) do
    session
    |> Map.put(:transcript_path, path)
    |> Map.delete(:transcript_cursor)
    |> Map.delete(:transcript_cursor_path)
  end

  defp put_transcript_cursor(session, transcript_path, cursor) do
    session
    |> maybe_put_transcript_path(transcript_path)
    |> Map.put(:transcript_cursor, cursor)
    |> Map.put(:transcript_cursor_path, transcript_path)
  end

  defp append_new_assistant_messages(session, messages) do
    Enum.reduce(messages, {session, []}, fn message, {current, accepted} ->
      text = normalize_history_text(message)
      fingerprint = text_fingerprint(text)

      cond do
        text == "" ->
          {current, accepted}

        fingerprint == current[:last_assistant_fingerprint] ->
          {current, accepted}

        true ->
          updated =
            current
            |> append_history_entry(:assistant, text)
            |> Map.put(:last_assistant_fingerprint, fingerprint)

          {updated, accepted ++ [text]}
      end
    end)
  end

  defp append_history_entry(session, role, text) do
    normalized = normalize_history_text(text)

    if normalized == "" do
      session
    else
      history = Map.get(session, :history, [])
      entry = %{role: role, text: normalized, at: System.system_time(:millisecond)}

      updated_history =
        case List.last(history) do
          %{role: ^role, text: ^normalized} -> history
          _ -> history ++ [entry]
        end

      max_entries = Application.get_env(:claude_notify, :terminal_history_max_entries, 60)
      Map.put(session, :history, Enum.take(updated_history, -max_entries))
    end
  end

  defp normalize_prompt(prompt), do: String.slice(prompt, 0, 500)

  defp normalize_history_text(text) do
    max_bytes = Application.get_env(:claude_notify, :terminal_history_max_entry_bytes, 6_000)

    text
    |> String.trim()
    |> truncate_utf8(max_bytes)
  end

  defp truncate_utf8(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp truncate_utf8(text, max_bytes) do
    {chunks, _bytes} =
      Enum.reduce_while(String.graphemes(text), {[], 0}, fn grapheme, {acc, bytes} ->
        next_bytes = bytes + byte_size(grapheme)

        if next_bytes > max_bytes do
          {:halt, {acc, bytes}}
        else
          {:cont, {[grapheme | acc], next_bytes}}
        end
      end)

    chunks
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp text_fingerprint(text) do
    :crypto.hash(:sha256, text)
    |> Base.encode16(case: :lower)
  end

  defp maybe_put_engine(session, nil), do: session
  defp maybe_put_engine(session, engine), do: Map.put(session, :engine, normalize_engine(engine))

  defp normalize_engine("codex"), do: "codex"
  defp normalize_engine(_), do: "claude"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, "unknown"), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp persist(%{path: nil}), do: :ok

  defp persist(state) do
    data =
      :erlang.term_to_binary(%{
        sessions: state.sessions,
        message_map: state.message_map,
        notification_text: state.notification_text,
        bindings: state.bindings
      })

    tmp_path = state.path <> ".tmp"
    File.mkdir_p!(Path.dirname(state.path))
    File.write!(tmp_path, data)
    File.chmod!(tmp_path, 0o600)
    File.rename!(tmp_path, state.path)
    :ok
  end

  defp load(nil), do: %__MODULE__{}

  defp load(path) do
    with true <- File.exists?(path),
         {:ok, binary} <- File.read(path),
         {:ok, data} <- safe_decode(binary) do
      sessions =
        data
        |> Map.get(:sessions, %{})
        |> Enum.map(fn {session_id, session} ->
          {session_id, Map.put_new(session, :history, [])}
        end)
        |> Map.new()
        |> filter_terminal_sessions()

      session_ids = Map.keys(sessions) |> MapSet.new()

      message_map =
        data
        |> Map.get(:message_map, %{})
        |> Enum.filter(fn {_mid, session_id} -> MapSet.member?(session_ids, session_id) end)
        |> Map.new()

      bindings =
        data
        |> Map.get(:bindings, %{})
        |> Enum.filter(fn {_chat_id, session_id} -> MapSet.member?(session_ids, session_id) end)
        |> Map.new()

      %__MODULE__{
        sessions: sessions,
        message_map: message_map,
        bindings: bindings,
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
