defmodule ClaudeNotify.ActivityTracker do
  @moduledoc """
  GenServer that manages edit-in-place activity messages for each session.
  Batches tool events and edits Telegram messages at most every `throttle_ms`.
  """
  use GenServer
  require Logger

  alias ClaudeNotify.MessageFormatter

  @default_throttle_ms 2_000

  defmodule SessionActivity do
    defstruct [
      :project,
      :message_id,
      :current_tool,
      :current_detail,
      action_count: 0,
      files_touched: MapSet.new(),
      dirty: false,
      timer_ref: nil
    ]
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  def track_tool(
        pid \\ __MODULE__,
        session_id,
        %{project: _, tool_name: _, tool_detail: _} = info
      ) do
    GenServer.cast(pid, {:track_tool, session_id, info})
  end

  def pause_session(pid \\ __MODULE__, session_id) do
    GenServer.cast(pid, {:pause, session_id})
  end

  def resume_session(pid \\ __MODULE__, session_id) do
    GenServer.cast(pid, {:resume, session_id})
  end

  def end_session(pid \\ __MODULE__, session_id) do
    GenServer.cast(pid, {:end_session, session_id})
  end

  def get_state(pid \\ __MODULE__, session_id) do
    GenServer.call(pid, {:get_state, session_id})
  end

  # Server

  @impl true
  def init(opts) do
    send_fn = opts[:send_fn] || (&default_send/2)
    throttle_ms = opts[:throttle_ms] || @default_throttle_ms
    {:ok, %{sessions: %{}, send_fn: send_fn, throttle_ms: throttle_ms}}
  end

  @impl true
  def handle_cast({:track_tool, session_id, info}, state) do
    session_activity =
      Map.get(state.sessions, session_id, %SessionActivity{project: info.project})

    file = extract_filename(info.tool_name, info.tool_detail)

    updated = %{
      session_activity
      | action_count: session_activity.action_count + 1,
        current_tool: info.tool_name,
        current_detail: info.tool_detail,
        files_touched:
          if(file,
            do: MapSet.put(session_activity.files_touched, file),
            else: session_activity.files_touched
          ),
        dirty: true
    }

    updated = maybe_schedule_flush(updated, session_id, state.throttle_ms)
    {:noreply, put_in(state, [:sessions, session_id], updated)}
  end

  @impl true
  def handle_cast({:pause, session_id}, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:noreply, state}

      activity ->
        cancel_timer(activity.timer_ref)
        text = MessageFormatter.activity_message_waiting(activity_to_map(activity))

        if activity.message_id do
          state.send_fn.(:edit, {activity.message_id, text})
        end

        updated = %{activity | dirty: false, timer_ref: nil}
        {:noreply, put_in(state, [:sessions, session_id], updated)}
    end
  end

  @impl true
  def handle_cast({:resume, session_id}, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:noreply, state}

      activity ->
        cancel_timer(activity.timer_ref)
        updated = %SessionActivity{project: activity.project}
        {:noreply, put_in(state, [:sessions, session_id], updated)}
    end
  end

  @impl true
  def handle_cast({:end_session, session_id}, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:noreply, state}

      activity ->
        cancel_timer(activity.timer_ref)
        {:noreply, %{state | sessions: Map.delete(state.sessions, session_id)}}
    end
  end

  @impl true
  def handle_call({:get_state, session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil -> {:reply, nil, state}
      activity -> {:reply, activity_to_map(activity), state}
    end
  end

  @impl true
  def handle_info({:flush, session_id}, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:noreply, state}

      %{dirty: false} = activity ->
        {:noreply, put_in(state, [:sessions, session_id], %{activity | timer_ref: nil})}

      activity ->
        text = MessageFormatter.activity_message(activity_to_map(activity))

        updated =
          if activity.message_id do
            state.send_fn.(:edit, {activity.message_id, text})
            %{activity | dirty: false, timer_ref: nil}
          else
            case state.send_fn.(:send, {text}) do
              {:ok, %{"result" => %{"message_id" => mid}}} ->
                %{activity | message_id: mid, dirty: false, timer_ref: nil}

              _ ->
                %{activity | dirty: false, timer_ref: nil}
            end
          end

        {:noreply, put_in(state, [:sessions, session_id], updated)}
    end
  end

  # Helpers

  defp maybe_schedule_flush(%{timer_ref: nil} = activity, session_id, throttle_ms) do
    ref = Process.send_after(self(), {:flush, session_id}, throttle_ms)
    %{activity | timer_ref: ref}
  end

  defp maybe_schedule_flush(activity, _session_id, _throttle_ms), do: activity

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp activity_to_map(activity) do
    %{
      project: activity.project,
      action_count: activity.action_count,
      files_touched: activity.files_touched,
      current_tool: activity.current_tool,
      current_detail: activity.current_detail
    }
  end

  defp extract_filename(tool, detail)
       when tool in ["Read", "Write", "Edit"] and is_binary(detail) do
    Path.basename(detail)
  end

  defp extract_filename(_, _), do: nil

  defp default_send(:send, {text}) do
    ClaudeNotify.Telegram.send_message_with_retry(text)
  end

  defp default_send(:edit, {message_id, text}) do
    ClaudeNotify.Telegram.edit_message_text_with_retry(message_id, text)
  end
end
