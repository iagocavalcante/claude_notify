defmodule ClaudeNotify.ProjectScopeTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.{ProjectRegistry, ProjectScope}
  alias ClaudeNotify.ProjectScope.Scope

  setup do
    tmp = Path.join(System.tmp_dir!(), "project_scope_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  defp git_repo!(root, relative_path) do
    path = Path.join(root, relative_path)
    File.mkdir_p!(path)
    {_, 0} = System.cmd("git", ["init", "--quiet", path])
    {_, 0} = System.cmd("git", ["-C", path, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", path, "config", "user.name", "Test"])
    File.write!(Path.join(path, "README.md"), "fixture\n")
    {_, 0} = System.cmd("git", ["-C", path, "add", "README.md"])
    {_, 0} = System.cmd("git", ["-C", path, "commit", "--quiet", "-m", "initial"])
    path
  end

  defp registry(projects, tmp) do
    ProjectRegistry.load(
      projects: projects,
      workspace_roots: [],
      config_path: Path.join(tmp, "missing-projects.json")
    )
  end

  defp physical(path) do
    {output, 0} = System.cmd("pwd", ["-P"], cd: path)
    String.trim(output)
  end

  test "repository root and nested cwd resolve to one canonical scope", %{tmp: tmp} do
    repo = git_repo!(tmp, "widgets")
    nested = Path.join([repo, "apps", "web"])
    File.mkdir_p!(nested)
    registry = registry([%{name: "widgets", path: repo}], tmp)

    assert {:ok, %Scope{} = root_scope} = ProjectScope.resolve(repo, registry)
    assert {:ok, %Scope{} = nested_scope} = ProjectScope.resolve(nested, registry)

    assert root_scope.id == nested_scope.id
    assert nested_scope.name == "widgets"
    assert nested_scope.repo_root == physical(repo)
    assert nested_scope.worktree_root == physical(repo)
    assert nested_scope.cwd == physical(nested)
  end

  test "linked and generated-style worktrees resolve to the source project", %{tmp: tmp} do
    repo = git_repo!(tmp, "widgets")
    worktree = Path.join(tmp, "generated-worktrees/job-42")
    File.mkdir_p!(Path.dirname(worktree))

    {_, 0} =
      System.cmd("git", ["-C", repo, "worktree", "add", "--quiet", "-b", "job-42", worktree])

    registry = registry([%{name: "widgets", path: repo}], tmp)

    assert {:ok, source_scope} = ProjectScope.resolve(repo, registry)
    assert {:ok, worktree_scope} = ProjectScope.resolve(worktree, registry)

    assert worktree_scope.id == source_scope.id
    assert worktree_scope.name == "widgets"
    assert worktree_scope.repo_root == physical(repo)
    assert worktree_scope.worktree_root == physical(worktree)
    assert worktree_scope.git_common_dir == source_scope.git_common_dir
  end

  test "repositories with the same basename retain distinct names and ids", %{tmp: tmp} do
    first = git_repo!(tmp, "acme/app")
    second = git_repo!(tmp, "personal/app")

    registry =
      registry(
        [
          %{name: "acme/app", path: first},
          %{name: "personal/app", path: second}
        ],
        tmp
      )

    assert {:ok, first_scope} = ProjectScope.resolve(first, registry)
    assert {:ok, second_scope} = ProjectScope.resolve(second, registry)

    assert first_scope.name == "acme/app"
    assert second_scope.name == "personal/app"
    refute first_scope.id == second_scope.id
  end

  test "path prefixes never make an unrelated repository eligible", %{tmp: tmp} do
    repo = git_repo!(tmp, "repo")
    other = git_repo!(tmp, "repo-other")
    registry = registry([%{name: "repo", path: repo}], tmp)

    assert {:ok, %{name: "repo"}} = ProjectScope.resolve(repo, registry)
    assert {:error, :unregistered_project} = ProjectScope.resolve(other, registry)
  end

  test "unknown, relative, missing, and non-git paths fail closed", %{tmp: tmp} do
    repo = git_repo!(tmp, "known")
    plain = Path.join(tmp, "plain")
    File.mkdir_p!(plain)
    registry = registry([%{name: "known", path: repo}], tmp)

    assert {:error, :invalid_cwd} = ProjectScope.resolve("relative/path", registry)
    assert {:error, :invalid_cwd} = ProjectScope.resolve(Path.join(tmp, "missing"), registry)
    assert {:error, :not_git_repository} = ProjectScope.resolve(plain, registry)
  end

  test "aliases resolve to the canonical name and identity", %{tmp: tmp} do
    repo = git_repo!(tmp, "widgets")
    registry = registry([%{name: "widgets", path: repo, aliases: ["w"]}], tmp)

    assert {:ok, scope} = ProjectScope.for_project(registry, "w")
    assert scope.name == "widgets"
    assert scope.repo_root == physical(repo)
    assert String.starts_with?(scope.id, "project_")
  end

  test "a non-exact worktree fails closed when one git identity has multiple registrations", %{
    tmp: tmp
  } do
    repo = git_repo!(tmp, "widgets")
    registered_worktree = Path.join(tmp, "registered-worktree")
    third_worktree = Path.join(tmp, "third-worktree")

    {_, 0} =
      System.cmd(
        "git",
        ["-C", repo, "worktree", "add", "--quiet", "-b", "registered", registered_worktree]
      )

    {_, 0} =
      System.cmd(
        "git",
        ["-C", repo, "worktree", "add", "--quiet", "-b", "third", third_worktree]
      )

    registry =
      registry(
        [
          %{name: "widgets-main", path: repo},
          %{name: "widgets-linked", path: registered_worktree}
        ],
        tmp
      )

    assert {:error, {:ambiguous_project, ["widgets-linked", "widgets-main"]}} =
             ProjectScope.resolve(third_worktree, registry)
  end
end
