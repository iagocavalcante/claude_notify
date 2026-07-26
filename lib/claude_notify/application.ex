defmodule ClaudeNotify.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:claude_notify, :port, 4040)
    max_event_concurrency = Application.get_env(:claude_notify, :max_event_concurrency, 8)

    children =
      [
        ClaudeNotify.SessionStore,
        ClaudeNotify.ActivityTracker,
        ClaudeNotify.TaskTracker,
        ClaudeNotify.Dashboard,
        ClaudeNotify.JobStore,
        ClaudeNotify.JobTranscript,
        ClaudeNotify.JobSupervisor,
        ClaudeNotify.JobSupervisor.Dispatcher
      ] ++
        reconciler_child() ++
        [
          {Task.Supervisor,
           name: ClaudeNotify.EventTaskSupervisor, max_children: max_event_concurrency},
          {Bandit, plug: ClaudeNotify.Router, port: port}
        ] ++ poller_child()

    opts = [strategy: :one_for_one, name: ClaudeNotify.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp poller_child do
    if Application.get_env(:claude_notify, :start_poller, true) do
      [ClaudeNotify.TelegramPoller]
    else
      []
    end
  end

  # Runs ClaudeNotify.JobReconciler once, right after JobStore/JobSupervisor
  # are up. `Task`'s default child_spec is `restart: :temporary`, matching
  # the one-shot nature of a boot reconciliation pass - if it somehow
  # crashes despite its own internal rescue, :one_for_one means the rest of
  # the app keeps booting. Disabled by default under :test so `mix test`
  # never reconciles against a developer's real ~/.claude_notify state (see
  # :start_poller above for the same concern/pattern).
  defp reconciler_child do
    if Application.get_env(:claude_notify, :start_job_reconciler, true) do
      [{Task, &ClaudeNotify.JobReconciler.run/0}]
    else
      []
    end
  end
end
