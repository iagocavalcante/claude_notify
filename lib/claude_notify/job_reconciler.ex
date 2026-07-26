defmodule ClaudeNotify.JobReconciler do
  @moduledoc """
  Runs once at application boot to reconcile `ClaudeNotify.JobStore` against
  reality after a restart:

    * Jobs left in `:running` status are, by construction, orphaned - no
      `ClaudeNotify.JobRunner` survives an app restart (runners are
      `restart: :temporary` and the `Job` struct tracks no OS PID), so a
      `:running` job at boot always means its process is gone. Each such job
      is transitioned to `:failed`, and its tracked Telegram message(s), if
      any, are edited to say it was interrupted.
    * On-disk worktrees with no matching `JobStore` record are orphans -
      listed and reported to the authorized Telegram chat with a cleanup
      prompt. They are never auto-deleted.
    * Worktrees belonging to `:completed`/`:discarded` jobs older than the
      configured retention window (`:claude_notify,
      :job_worktree_retention_seconds`, default 7 days, judged against the
      job's `updated_at`) are swept via `ClaudeNotify.WorktreeManager.discard/1`.

  Meant to be started as a one-shot `Task` from `ClaudeNotify.Application`,
  after `JobStore` and `JobSupervisor` are already up. Never raises: any
  failure is caught, logged, and reconciliation simply stops there rather
  than crashing the supervision tree - a partial reconciliation pass is
  safer than taking the whole app down at boot.
  """

  require Logger

  alias ClaudeNotify.{JobStore, ProjectRegistry, Telegram, WorktreeManager}
  alias ClaudeNotify.WorktreeManager.Worktree

  @default_retention_seconds 60 * 60 * 24 * 7

  @doc """
  Runs the full reconciliation pass described in the moduledoc.

  Options (all optional - present for testability, boot uses the defaults):

    * `:job_store` - `JobStore` name/pid, defaults to `ClaudeNotify.JobStore`.
    * `:telegram` - module implementing `send_message/1` and
      `edit_message_text/2`, defaults to `ClaudeNotify.Telegram`.
    * `:project_registry` - a preloaded `ProjectRegistry.t()`, defaults to
      loading one via `ProjectRegistry.load/0`.
    * `:retention_seconds` - overrides the configured retention window.

  Always returns `:ok`.
  """
  def run(opts \\ []) do
    job_store = Keyword.get(opts, :job_store, JobStore)
    telegram = Keyword.get(opts, :telegram, Telegram)
    registry = Keyword.get_lazy(opts, :project_registry, fn -> ProjectRegistry.load() end)
    retention_seconds = Keyword.get(opts, :retention_seconds, configured_retention_seconds())

    interrupted = reconcile_interrupted_jobs(job_store, telegram)
    orphans = find_orphan_worktrees(job_store, registry)
    swept = sweep_retention(job_store, registry, retention_seconds)

    report_summary(telegram, interrupted, orphans, swept)
    :ok
  rescue
    error ->
      Logger.error(
        "JobReconciler: boot reconciliation crashed, boot proceeds anyway: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  # -- Interrupted jobs --

  defp reconcile_interrupted_jobs(job_store, telegram) do
    job_store
    |> JobStore.list(status: :running)
    |> Enum.map(&interrupt_job(job_store, telegram, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp interrupt_job(job_store, telegram, job) do
    case JobStore.update_status(job_store, job.id, :failed, %{}) do
      {:ok, _updated} ->
        Logger.warning(
          "JobReconciler: job #{job.id} was :running at boot with no surviving process - " <>
            "marking failed (interrupted)"
        )

        notify_interrupted(telegram, job)
        job.id

      {:error, reason} ->
        Logger.error(
          "JobReconciler: could not mark job #{job.id} failed at boot: #{inspect(reason)}"
        )

        nil
    end
  end

  defp notify_interrupted(_telegram, %{telegram_message_ids: []}), do: :ok

  defp notify_interrupted(telegram, job) do
    text =
      "Job ##{job.id} (#{job.project}) was interrupted by an app restart and is now marked failed."

    Enum.each(job.telegram_message_ids, fn message_id ->
      case telegram.edit_message_text(message_id, text) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "JobReconciler: could not edit telegram message #{message_id} for job " <>
              "#{job.id}: #{inspect(reason)}"
          )
      end
    end)
  end

  # -- Orphan worktrees --

  defp find_orphan_worktrees(job_store, registry) do
    known_job_ids = job_store |> JobStore.list() |> MapSet.new(&to_string(&1.id))

    registry
    |> ProjectRegistry.known_projects()
    |> Enum.flat_map(&list_project_worktrees(&1, registry))
    |> Enum.reject(&MapSet.member?(known_job_ids, &1.job_id))
  end

  defp list_project_worktrees(project_name, registry) do
    with {:ok, repo_path} <- ProjectRegistry.lookup(registry, project_name),
         {:ok, worktrees} <- WorktreeManager.list(repo_path) do
      worktrees
    else
      {:error, reason} ->
        Logger.warning(
          "JobReconciler: could not list worktrees for project #{project_name}: " <>
            inspect(reason)
        )

        []
    end
  end

  # -- Retention sweep --

  defp sweep_retention(job_store, registry, retention_seconds) do
    now = System.system_time(:second)

    job_store
    |> JobStore.list()
    |> Enum.filter(&past_retention?(&1, now, retention_seconds))
    |> Enum.map(&sweep_job_worktree(&1, registry))
    |> Enum.reject(&is_nil/1)
  end

  defp past_retention?(job, now, retention_seconds) do
    job.status in [:completed, :discarded] and is_binary(job.worktree_path) and
      now - job.updated_at >= retention_seconds
  end

  defp sweep_job_worktree(job, registry) do
    with {:ok, repo_path} <- ProjectRegistry.lookup(registry, job.project),
         worktree = %Worktree{
           repo_path: repo_path,
           job_id: to_string(job.id),
           path: job.worktree_path,
           branch: job.branch
         },
         :ok <- WorktreeManager.discard(worktree) do
      Logger.info("JobReconciler: swept worktree for job #{job.id} (past retention window)")
      job.id
    else
      {:error, reason} ->
        Logger.warning(
          "JobReconciler: could not sweep worktree for job #{job.id}: #{inspect(reason)}"
        )

        nil
    end
  end

  # -- Summary report --

  defp report_summary(_telegram, [], [], []), do: :ok

  defp report_summary(telegram, interrupted, orphans, swept) do
    telegram.send_message(summary_text(interrupted, orphans, swept))
    :ok
  end

  defp summary_text(interrupted, orphans, swept) do
    ["Boot reconciliation report:"]
    |> Kernel.++(List.wrap(interrupted_line(interrupted)))
    |> Kernel.++(List.wrap(orphan_line(orphans)))
    |> Kernel.++(List.wrap(swept_line(swept)))
    |> Enum.join("\n")
  end

  defp interrupted_line([]), do: nil

  defp interrupted_line(ids) do
    "- #{length(ids)} interrupted job(s) marked failed: #{Enum.join(ids, ", ")}"
  end

  defp orphan_line([]), do: nil

  defp orphan_line(orphans) do
    listing = Enum.map_join(orphans, "; ", &"#{&1.path} (job #{&1.job_id}, branch #{&1.branch})")

    "- #{length(orphans)} orphan worktree(s), no matching job record - " <>
      "review and clean up manually: #{listing}"
  end

  defp swept_line([]), do: nil

  defp swept_line(ids) do
    "- #{length(ids)} worktree(s) swept past retention window: " <>
      Enum.map_join(ids, ", ", &to_string/1)
  end

  defp configured_retention_seconds do
    Application.get_env(
      :claude_notify,
      :job_worktree_retention_seconds,
      @default_retention_seconds
    )
  end
end
