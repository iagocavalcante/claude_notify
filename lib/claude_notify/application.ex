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
        ClaudeNotify.Dashboard,
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
end
