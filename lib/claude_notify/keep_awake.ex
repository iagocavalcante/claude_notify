defmodule ClaudeNotify.KeepAwake do
  @moduledoc """
  Prevents macOS idle sleep while coding work is in progress.

  The process owns one `caffeinate -i` child and releases it as soon as all
  terminal sessions and dispatcher jobs become idle or finish. Display sleep
  is intentionally unaffected.

  With `keep_awake_while_idle: true` (`CLAUDE_NOTIFY_KEEP_AWAKE_IDLE`), any
  registered terminal session holds the assertion, including idle ones, so a
  locked Mac stays reachable for scheduled wakeups and Telegram replies.
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
  def working?(sessions, jobs, previews \\ [], opts \\ []) do
    session_values = if is_map(sessions), do: Map.values(sessions), else: sessions
    include_idle? = Keyword.get(opts, :include_idle, false)

    Enum.any?(session_values, &(include_idle? or &1[:status] in @working_session_statuses)) or
      Enum.any?(jobs, &(&1.status in @working_job_statuses)) or previews != []
  end

  @impl true
  def init(opts) do
    send(self(), :refresh)

    {:ok,
     %{
       port: nil,
       executable: opts[:executable] || "/usr/bin/caffeinate",
       refresh_interval: opts[:refresh_interval] || @refresh_interval,
       include_idle:
         Keyword.get(
           opts,
           :include_idle,
           Application.get_env(:claude_notify, :keep_awake_while_idle, false)
         )
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
      working?(SessionStore.terminal_sessions(), JobStore.list(), PreviewManager.list(),
        include_idle: state.include_idle
      )

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

  # Closing the port only closes caffeinate's stdin; `caffeinate -w` keeps
  # running until the watched VM exits, so the OS process must be killed or
  # every work cycle leaks one more sleep assertion.
  defp stop_caffeinate(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", [Integer.to_string(os_pid)], stderr_to_stdout: true)
        Port.close(port)

      nil ->
        :ok
    end

    :ok
  rescue
    ArgumentError -> :ok
  end
end
