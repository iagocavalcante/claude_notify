defmodule ClaudeNotify.JobReconcilerTest do
  use ExUnit.Case, async: false

  alias ClaudeNotify.{JobReconciler, JobStore, ProjectRegistry, WorktreeManager}

  @moduletag :tmp_dir

  # `JobReconciler.run/1` is invoked synchronously in the test process below
  # (it's a plain function, not a spawned Task), so `self()` inside this fake
  # resolves to the test process - no registration or mocking library needed.
  defmodule FakeTelegram do
    def send_message(text) do
      send(self(), {:telegram_send, text})
      {:ok, %{}}
    end

    def edit_message_text(message_id, text) do
      send(self(), {:telegram_edit, message_id, text})
      {:ok, %{}}
    end
  end

  setup %{tmp_dir: tmp_dir} do
    repo_path = create_fixture_repo(tmp_dir)
    base_dir = Path.join(tmp_dir, "worktrees_base")
    previous_base_dir = Application.get_env(:claude_notify, :worktree_base_dir)
    Application.put_env(:claude_notify, :worktree_base_dir, base_dir)

    on_exit(fn ->
      case previous_base_dir do
        nil -> Application.delete_env(:claude_notify, :worktree_base_dir)
        value -> Application.put_env(:claude_notify, :worktree_base_dir, value)
      end
    end)

    store = :"job_store_#{System.unique_integer([:positive])}"
    start_supervised!({JobStore, name: store, path: Path.join(tmp_dir, "jobs.dat")})

    registry = %ProjectRegistry{projects: %{"fixture" => repo_path}, aliases: %{}}

    %{repo_path: repo_path, store: store, registry: registry}
  end

  defp create_fixture_repo(tmp_dir) do
    path = Path.join(tmp_dir, "repo")
    File.mkdir_p!(path)

    {_, 0} = System.cmd("git", ["init", "-q"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: path)
    File.write!(Path.join(path, "README.md"), "fixture\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: path)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "initial commit"], cd: path)

    path
  end

  defp job_attrs(overrides \\ %{}) do
    Map.merge(%{engine: "claude", project: "fixture", prompt: "do the thing"}, overrides)
  end

  defp reconcile(store, registry, opts \\ []) do
    JobReconciler.run(
      Keyword.merge(
        [job_store: store, telegram: FakeTelegram, project_registry: registry],
        opts
      )
    )
  end

  describe "interrupted running jobs" do
    test "a :running job with no surviving process is marked failed and its message edited", %{
      store: store,
      registry: registry
    } do
      {:ok, job} = JobStore.create(store, job_attrs())

      {:ok, _} =
        JobStore.update_status(store, job.id, :running, %{telegram_message_ids: [111, 222]})

      assert :ok = reconcile(store, registry)

      assert JobStore.get(store, job.id).status == :failed

      assert_received {:telegram_edit, 111, text}
      assert text =~ "interrupted"
      assert_received {:telegram_edit, 222, ^text}
    end

    test "a job with empty telegram_message_ids is still marked failed with no edit attempted, but the summary still goes out",
         %{store: store, registry: registry} do
      {:ok, job} = JobStore.create(store, job_attrs())
      {:ok, _} = JobStore.update_status(store, job.id, :running, %{})

      assert :ok = reconcile(store, registry)

      assert JobStore.get(store, job.id).status == :failed
      refute_received {:telegram_edit, _, _}
      assert_received {:telegram_send, summary}
      assert summary =~ "interrupted"
    end

    test "queued and already-terminal jobs are left untouched", %{
      store: store,
      registry: registry
    } do
      {:ok, queued} = JobStore.create(store, job_attrs())
      {:ok, done_job} = JobStore.create(store, job_attrs())
      {:ok, _} = JobStore.update_status(store, done_job.id, :running, %{})
      {:ok, _} = JobStore.update_status(store, done_job.id, :completed, %{})

      assert :ok = reconcile(store, registry)

      assert JobStore.get(store, queued.id).status == :queued
      assert JobStore.get(store, done_job.id).status == :completed
    end
  end

  describe "orphan worktrees" do
    test "a worktree on disk with no matching job record is reported, never deleted", %{
      repo_path: repo_path,
      store: store,
      registry: registry
    } do
      {:ok, orphan} = WorktreeManager.create(repo_path, "999", "orphan")

      assert :ok = reconcile(store, registry)

      assert_received {:telegram_send, summary}
      assert summary =~ "999"
      assert summary =~ "orphan"

      assert {:ok, worktrees} = WorktreeManager.list(repo_path)
      assert Enum.any?(worktrees, &(&1.path == orphan.path))
    end

    test "a worktree matching a known job id is not reported as an orphan", %{
      repo_path: repo_path,
      store: store,
      registry: registry
    } do
      {:ok, job} = JobStore.create(store, job_attrs())
      {:ok, _worktree} = WorktreeManager.create(repo_path, to_string(job.id), "run")

      assert :ok = reconcile(store, registry)

      refute_received {:telegram_send, _}
    end

    test "gracefully skips orphan scanning for a project whose worktree listing fails", %{
      store: store,
      tmp_dir: tmp_dir
    } do
      not_a_repo = Path.join(tmp_dir, "not_a_repo")
      File.mkdir_p!(not_a_repo)
      registry = %ProjectRegistry{projects: %{"broken" => not_a_repo}, aliases: %{}}

      assert :ok = reconcile(store, registry)
    end
  end

  describe "retention sweep" do
    test "sweeps completed worktrees past the retention window, leaves non-terminal ones alone",
         %{repo_path: repo_path, store: store, registry: registry} do
      {:ok, completed_job} = JobStore.create(store, job_attrs())
      {:ok, worktree} = WorktreeManager.create(repo_path, to_string(completed_job.id), "run")

      {:ok, _} =
        JobStore.update(store, completed_job.id, %{
          worktree_path: worktree.path,
          branch: worktree.branch
        })

      {:ok, _} = JobStore.update_status(store, completed_job.id, :running, %{})
      {:ok, _} = JobStore.update_status(store, completed_job.id, :completed, %{})

      {:ok, queued_job} = JobStore.create(store, job_attrs())
      {:ok, queued_worktree} = WorktreeManager.create(repo_path, to_string(queued_job.id), "run")

      {:ok, _} =
        JobStore.update(store, queued_job.id, %{
          worktree_path: queued_worktree.path,
          branch: queued_worktree.branch
        })

      assert :ok = reconcile(store, registry, retention_seconds: 0)

      assert {:ok, remaining} = WorktreeManager.list(repo_path)
      remaining_paths = Enum.map(remaining, & &1.path)

      refute worktree.path in remaining_paths
      assert queued_worktree.path in remaining_paths

      assert_received {:telegram_send, summary}
      assert summary =~ "swept"
    end

    test "does not sweep a completed job's worktree while still inside the retention window", %{
      repo_path: repo_path,
      store: store,
      registry: registry
    } do
      {:ok, job} = JobStore.create(store, job_attrs())
      {:ok, worktree} = WorktreeManager.create(repo_path, to_string(job.id), "run")

      {:ok, _} =
        JobStore.update(store, job.id, %{worktree_path: worktree.path, branch: worktree.branch})

      {:ok, _} = JobStore.update_status(store, job.id, :running, %{})
      {:ok, _} = JobStore.update_status(store, job.id, :completed, %{})

      assert :ok = reconcile(store, registry, retention_seconds: 60 * 60 * 24 * 7)

      assert {:ok, remaining} = WorktreeManager.list(repo_path)
      assert Enum.any?(remaining, &(&1.path == worktree.path))
    end

    test "gracefully skips sweeping a job whose project is no longer registered", %{store: store} do
      {:ok, job} =
        JobStore.create(
          store,
          job_attrs(%{
            project: "gone-project",
            worktree_path: "/tmp/does-not-matter",
            branch: "job/x"
          })
        )

      {:ok, _} = JobStore.update_status(store, job.id, :running, %{})
      {:ok, _} = JobStore.update_status(store, job.id, :completed, %{})

      empty_registry = %ProjectRegistry{projects: %{}, aliases: %{}}

      assert :ok = reconcile(store, empty_registry, retention_seconds: 0)
      assert JobStore.get(store, job.id).status == :completed
    end
  end

  describe "boot safety" do
    test "a clean boot with nothing to reconcile sends no summary", %{
      store: store,
      registry: registry
    } do
      {:ok, _job} = JobStore.create(store, job_attrs())

      assert :ok = reconcile(store, registry)

      refute_received {:telegram_send, _}
      refute_received {:telegram_edit, _, _}
    end
  end
end
