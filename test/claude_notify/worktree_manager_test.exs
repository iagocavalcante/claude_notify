defmodule ClaudeNotify.WorktreeManagerTest do
  use ExUnit.Case, async: false

  alias ClaudeNotify.WorktreeManager
  alias ClaudeNotify.WorktreeManager.Worktree

  setup do
    repo_path = create_fixture_repo()
    base_dir = Path.join(System.tmp_dir!(), "wtm_base_#{System.unique_integer([:positive])}")

    previous_base_dir = Application.get_env(:claude_notify, :worktree_base_dir)
    Application.put_env(:claude_notify, :worktree_base_dir, base_dir)

    on_exit(fn ->
      File.rm_rf(repo_path)
      File.rm_rf(base_dir)

      case previous_base_dir do
        nil -> Application.delete_env(:claude_notify, :worktree_base_dir)
        value -> Application.put_env(:claude_notify, :worktree_base_dir, value)
      end
    end)

    %{repo_path: repo_path}
  end

  defp create_fixture_repo do
    path = Path.join(System.tmp_dir!(), "wtm_fixture_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    {_, 0} = System.cmd("git", ["init", "-q"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: path)
    File.write!(Path.join(path, "README.md"), "fixture\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: path)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "initial commit"], cd: path)

    path
  end

  defp current_branch(path) do
    {output, 0} = System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: path)
    String.trim(output)
  end

  defp branch_exists?(repo_path, branch) do
    case System.cmd("git", ["rev-parse", "--verify", "--quiet", "refs/heads/" <> branch],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      {_output, _code} -> false
    end
  end

  describe "create/3" do
    test "returns worktree path + branch name, checked out on the new branch", %{
      repo_path: repo_path
    } do
      assert {:ok, %Worktree{} = worktree} = WorktreeManager.create(repo_path, "42", "add-foo")

      assert worktree.branch == "job/42-add-foo"
      assert worktree.job_id == "42"
      assert worktree.repo_path == Path.expand(repo_path)
      assert File.dir?(worktree.path)
      assert current_branch(worktree.path) == "job/42-add-foo"
    end

    test "creating twice for the same job id fails cleanly with no half-state", %{
      repo_path: repo_path
    } do
      assert {:ok, first} = WorktreeManager.create(repo_path, "42", "add-foo")
      assert {:error, :already_exists} = WorktreeManager.create(repo_path, "42", "add-foo")

      assert File.dir?(first.path)
      assert current_branch(first.path) == "job/42-add-foo"
      assert {:ok, worktrees} = WorktreeManager.list(repo_path)
      assert length(worktrees) == 1
    end

    test "rejects a job id containing unsafe characters" do
      assert {:error, _reason} = WorktreeManager.create("/tmp/whatever", "../etc", "slug")
    end

    test "rejects a slug containing unsafe characters", %{repo_path: repo_path} do
      assert {:error, _reason} = WorktreeManager.create(repo_path, "42", "../../etc")
    end
  end

  describe "reuse/3" do
    test "returns only an exact Git-registered app worktree", %{repo_path: repo_path} do
      {:ok, worktree} = WorktreeManager.create(repo_path, "43", "chat")

      assert {:ok, reused} =
               WorktreeManager.reuse(repo_path, worktree.path, worktree.branch)

      assert reused.path == worktree.path
      assert reused.branch == worktree.branch

      assert {:error, :unregistered_worktree} =
               WorktreeManager.reuse(repo_path, repo_path, worktree.branch)

      assert {:error, :unregistered_worktree} =
               WorktreeManager.reuse(repo_path, worktree.path, "main")

      assert {:error, :missing_worktree} =
               WorktreeManager.reuse(repo_path, Path.join(repo_path, "missing"), worktree.branch)
    end
  end

  describe "discard/1" do
    test "removes the worktree directory and deletes the branch", %{repo_path: repo_path} do
      {:ok, worktree} = WorktreeManager.create(repo_path, "7", "cleanup")

      assert :ok = WorktreeManager.discard(worktree)
      refute File.exists?(worktree.path)
      refute branch_exists?(repo_path, worktree.branch)
    end

    test "running discard twice is idempotent", %{repo_path: repo_path} do
      {:ok, worktree} = WorktreeManager.create(repo_path, "8", "twice")

      assert :ok = WorktreeManager.discard(worktree)
      assert :ok = WorktreeManager.discard(worktree)
    end

    test "force-removes a dirty worktree with uncommitted changes", %{repo_path: repo_path} do
      {:ok, worktree} = WorktreeManager.create(repo_path, "9", "dirty")
      File.write!(Path.join(worktree.path, "scratch.txt"), "uncommitted\n")

      assert :ok = WorktreeManager.discard(worktree)
      refute File.exists?(worktree.path)
    end
  end

  describe "list/1" do
    test "returns an empty list when no job worktrees exist", %{repo_path: repo_path} do
      assert {:ok, []} = WorktreeManager.list(repo_path)
    end

    test "lists existing job worktrees for a repo", %{repo_path: repo_path} do
      {:ok, wt1} = WorktreeManager.create(repo_path, "1", "alpha")
      {:ok, wt2} = WorktreeManager.create(repo_path, "2", "beta")

      assert {:ok, worktrees} = WorktreeManager.list(repo_path)
      job_ids = worktrees |> Enum.map(& &1.job_id) |> Enum.sort()

      assert job_ids == ["1", "2"]
      assert Enum.any?(worktrees, &(&1.path == wt1.path and &1.branch == wt1.branch))
      assert Enum.any?(worktrees, &(&1.path == wt2.path and &1.branch == wt2.branch))
    end

    test "does not include the main repo checkout", %{repo_path: repo_path} do
      {:ok, _worktree} = WorktreeManager.create(repo_path, "3", "gamma")

      assert {:ok, worktrees} = WorktreeManager.list(repo_path)
      refute Enum.any?(worktrees, &(&1.path == Path.expand(repo_path)))
    end

    test "reflects removals made through discard/1", %{repo_path: repo_path} do
      {:ok, worktree} = WorktreeManager.create(repo_path, "4", "delta")
      assert :ok = WorktreeManager.discard(worktree)

      assert {:ok, []} = WorktreeManager.list(repo_path)
    end
  end
end
