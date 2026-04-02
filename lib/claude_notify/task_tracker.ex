defmodule ClaudeNotify.TaskTracker do
  @moduledoc """
  GenServer that tracks TaskCreate/TaskUpdate events per session
  and maintains an edit-in-place checklist message in Telegram.
  """
  use GenServer
  require Logger

  alias ClaudeNotify.MessageFormatter

  defmodule TaskEntry do
    defstruct [:subject, status: :pending]
  end

  defmodule SessionTasks do
    defstruct tasks: [], message_id: nil
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  def track_create(pid \\ __MODULE__, session_id, %{subject: _} = info) do
    GenServer.cast(pid, {:track_create, session_id, info})
  end

  def track_update(pid \\ __MODULE__, session_id, %{subject: _, status: _} = info) do
    GenServer.cast(pid, {:track_update, session_id, info})
  end

  def get_tasks(pid \\ __MODULE__, session_id) do
    GenServer.call(pid, {:get_tasks, session_id})
  end

  def end_session(pid \\ __MODULE__, session_id) do
    GenServer.cast(pid, {:end_session, session_id})
  end

  # Server

  @impl true
  def init(opts) do
    send_fn = opts[:send_fn] || (&default_send/2)
    {:ok, %{sessions: %{}, send_fn: send_fn}}
  end

  @impl true
  def handle_cast({:track_create, session_id, info}, state) do
    session_tasks = Map.get(state.sessions, session_id, %SessionTasks{})
    entry = %TaskEntry{subject: info.subject, status: :pending}
    updated = %{session_tasks | tasks: session_tasks.tasks ++ [entry]}
    state = put_in(state, [:sessions, session_id], updated)
    state = flush_checklist(session_id, state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:track_update, session_id, info}, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:noreply, state}

      session_tasks ->
        status = parse_status(info.status)

        updated_tasks =
          Enum.map(session_tasks.tasks, fn task ->
            if task.subject == info.subject do
              %{task | status: status}
            else
              task
            end
          end)

        updated = %{session_tasks | tasks: updated_tasks}
        state = put_in(state, [:sessions, session_id], updated)
        state = flush_checklist(session_id, state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:end_session, session_id}, state) do
    {:noreply, %{state | sessions: Map.delete(state.sessions, session_id)}}
  end

  @impl true
  def handle_call({:get_tasks, session_id}, _from, state) do
    tasks =
      case Map.get(state.sessions, session_id) do
        nil -> []
        session_tasks -> session_tasks.tasks
      end

    {:reply, tasks, state}
  end

  # Helpers

  defp flush_checklist(session_id, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        state

      session_tasks ->
        text = MessageFormatter.task_checklist(session_tasks.tasks)

        if session_tasks.message_id do
          state.send_fn.(:edit, {session_tasks.message_id, text})
          state
        else
          case state.send_fn.(:send, {text}) do
            {:ok, %{"result" => %{"message_id" => mid}}} ->
              updated = %{session_tasks | message_id: mid}
              put_in(state, [:sessions, session_id], updated)

            _ ->
              state
          end
        end
    end
  end

  defp parse_status("completed"), do: :completed
  defp parse_status("in_progress"), do: :in_progress
  defp parse_status("pending"), do: :pending
  defp parse_status(_), do: :pending

  defp default_send(:send, {text}) do
    ClaudeNotify.Telegram.send_message_with_retry(text)
  end

  defp default_send(:edit, {message_id, text}) do
    ClaudeNotify.Telegram.edit_message_text_with_retry(message_id, text)
  end
end
