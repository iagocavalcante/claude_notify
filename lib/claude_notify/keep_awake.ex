defmodule ClaudeNotify.KeepAwake do
  @moduledoc """
  Prevents macOS idle sleep while coding work is in progress.

  The process owns one `caffeinate -i` child and releases it as soon as all
  terminal sessions and dispatcher jobs become idle or finish. Display sleep
  is intentionally unaffected.
  """

  use GenServer

  require Logger

  alias ClaudeNotify.{JobStore, PreviewManager, SessionStore}

  @refresh_interval :timer.seconds(5)
  @working_session_statuses [:active, :waiting_input]
  @working_job_statuses [:queued, :running, :awaiting_input]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc false
  def working?(sessions, jobs, previews \\ []) do
    session_values = if is_map(sessions), do: Map.values(sessions), else: sessions

    Enum.any?(session_values, &(&1[:status] in @working_session_statuses)) or
      Enum.any?(jobs, &(&1.status in @working_job_statuses)) or previews != []
  end

  @impl true
  def init(opts) do
    send(self(), :refresh)

    {:ok,
     %{
       port: nil,
       executable: opts[:executable] || "/usr/bin/caffeinate",
       refresh_interval: opts[:refresh_interval] || @refresh_interval
     }}
  end

  @impl true
  def handle_info(:refresh, state) do
    state = reconcile(state)
    Process.send_after(self(), :refresh, state.refresh_interval)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if status != 0 do
      Logger.warning("KeepAwake: caffeinate exited with status #{status}")
    end

    {:noreply, %{state | port: nil}}
  end

  def handle_info({_port, {:exit_status, _status}}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_caffeinate(state.port)
    :ok
  end

  defp reconcile(state) do
    working =
      working?(SessionStore.terminal_sessions(), JobStore.list(), PreviewManager.list())

    cond do
      working and is_nil(state.port) -> start_caffeinate(state)
      not working and not is_nil(state.port) -> stop_caffeinate_process(state)
      true -> state
    end
  catch
    :exit, reason ->
      Logger.warning("KeepAwake: could not inspect current work: #{inspect(reason)}")
      state
  end

  defp start_caffeinate(state) do
    port =
      Port.open(
        {:spawn_executable, state.executable},
        [:binary, :exit_status, args: ["-i", "-w", System.pid()]]
      )

    Logger.info("KeepAwake: preventing idle system sleep while work is active")
    %{state | port: port}
  rescue
    error ->
      Logger.warning("KeepAwake: could not start caffeinate: #{Exception.message(error)}")
      state
  end

  defp stop_caffeinate_process(state) do
    stop_caffeinate(state.port)
    Logger.info("KeepAwake: released idle-sleep assertion")
    %{state | port: nil}
  end

  defp stop_caffeinate(nil), do: :ok

  defp stop_caffeinate(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
