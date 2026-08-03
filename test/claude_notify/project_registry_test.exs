defmodule ClaudeNotify.ProjectRegistryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ClaudeNotify.ProjectRegistry

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "project_registry_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  defp git_repo!(root, name) do
    path = Path.join(root, name)
    File.mkdir_p!(path)
    {_, 0} = System.cmd("git", ["init", "--quiet", path])
    path
  end

  defp missing_config_path(tmp), do: Path.join(tmp, "does_not_exist.json")

  describe "load/1 and lookup/2 with valid projects" do
    test "looks up a project by its canonical name", %{tmp: tmp} do
      repo = git_repo!(tmp, "widgets")

      registry =
        ProjectRegistry.load(
          projects: [%{name: "widgets", path: repo, aliases: ["w"]}],
          config_path: missing_config_path(tmp)
        )

      assert {:ok, ^repo} = ProjectRegistry.lookup(registry, "widgets")
    end

    test "looks up a project by an alias", %{tmp: tmp} do
      repo = git_repo!(tmp, "widgets")

      registry =
        ProjectRegistry.load(
          projects: [%{name: "widgets", path: repo, aliases: ["w", "widget"]}],
          config_path: missing_config_path(tmp)
        )

      assert {:ok, ^repo} = ProjectRegistry.lookup(registry, "w")
      assert {:ok, ^repo} = ProjectRegistry.lookup(registry, "widget")
    end

    test "a project with no aliases is still looked up by name", %{tmp: tmp} do
      repo = git_repo!(tmp, "widgets")

      registry =
        ProjectRegistry.load(
          projects: [%{name: "widgets", path: repo}],
          config_path: missing_config_path(tmp)
        )

      assert {:ok, ^repo} = ProjectRegistry.lookup(registry, "widgets")
    end
  end

  describe "lookup/2 for unknown projects" do
    test "returns a typed error, not a raise, listing known projects", %{tmp: tmp} do
      repo = git_repo!(tmp, "widgets")

      registry =
        ProjectRegistry.load(
          projects: [%{name: "widgets", path: repo}],
          config_path: missing_config_path(tmp)
        )

      assert {:error, {:unknown_project, "gadgets", known}} =
               ProjectRegistry.lookup(registry, "gadgets")

      assert known == ["widgets"]
    end

    test "empty registry still returns a typed error", %{tmp: tmp} do
      registry = ProjectRegistry.load(projects: [], config_path: missing_config_path(tmp))

      assert {:error, {:unknown_project, "anything", []}} =
               ProjectRegistry.lookup(registry, "anything")
    end
  end

  describe "workspace discovery" do
    test "discovers git repositories below a configured workspace root", %{tmp: tmp} do
      workspace = Path.join(tmp, "Workspaces")
      owner = Path.join(workspace, "acme")
      File.mkdir_p!(owner)
      repo = git_repo!(owner, "widgets")

      registry =
        ProjectRegistry.load(
          projects: [],
          workspace_roots: [workspace],
          workspace_discovery_depth: 3,
          config_path: missing_config_path(tmp)
        )

      assert {:ok, ^repo} = ProjectRegistry.lookup(registry, "widgets")
      assert ProjectRegistry.entries(registry) == [%{name: "widgets", path: repo}]
    end

    test "uses relative names when repositories share a basename", %{tmp: tmp} do
      workspace = Path.join(tmp, "Workspaces")
      first_owner = Path.join(workspace, "acme")
      second_owner = Path.join(workspace, "personal")
      File.mkdir_p!(first_owner)
      File.mkdir_p!(second_owner)
      first = git_repo!(first_owner, "app")
      second = git_repo!(second_owner, "app")

      registry =
        ProjectRegistry.load(
          projects: [],
          workspace_roots: [workspace],
          workspace_discovery_depth: 3,
          config_path: missing_config_path(tmp)
        )

      assert {:ok, ^first} = ProjectRegistry.lookup(registry, "acme/app")
      assert {:ok, ^second} = ProjectRegistry.lookup(registry, "personal/app")
    end

    test "explicit entries override an automatically discovered name", %{tmp: tmp} do
      workspace = Path.join(tmp, "Workspaces")
      File.mkdir_p!(workspace)
      _discovered = git_repo!(workspace, "widgets")
      explicit = git_repo!(tmp, "explicit_widgets")

      registry =
        ProjectRegistry.load(
          projects: [%{name: "widgets", path: explicit}],
          workspace_roots: [workspace],
          config_path: missing_config_path(tmp)
        )

      assert {:ok, ^explicit} = ProjectRegistry.lookup(registry, "widgets")
    end

    test "does not follow a workspace symlink to a repository outside the root", %{tmp: tmp} do
      workspace = Path.join(tmp, "Workspaces")
      File.mkdir_p!(workspace)
      outside = git_repo!(tmp, "outside")
      File.ln_s!(outside, Path.join(workspace, "linked-outside"))

      registry =
        ProjectRegistry.load(
          projects: [],
          workspace_roots: [workspace],
          config_path: missing_config_path(tmp)
        )

      assert ProjectRegistry.known_projects(registry) == []
    end
  end

  describe "validation at load" do
    test "rejects a configured path that does not exist, with a clear log", %{tmp: tmp} do
      missing_path = Path.join(tmp, "nope")

      {registry, log} =
        with_log(fn ->
          ProjectRegistry.load(
            projects: [%{name: "ghost", path: missing_path}],
            config_path: missing_config_path(tmp)
          )
        end)

      assert ProjectRegistry.known_projects(registry) == []
      assert {:error, {:unknown_project, "ghost", []}} = ProjectRegistry.lookup(registry, "ghost")
      assert log =~ "ghost"
      assert log =~ missing_path
    end

    test "rejects a path that exists but is not a git repo toplevel, with a clear log", %{
      tmp: tmp
    } do
      not_a_repo = Path.join(tmp, "just_a_dir")
      File.mkdir_p!(not_a_repo)

      {registry, log} =
        with_log(fn ->
          ProjectRegistry.load(
            projects: [%{name: "plain", path: not_a_repo}],
            config_path: missing_config_path(tmp)
          )
        end)

      assert ProjectRegistry.known_projects(registry) == []
      assert log =~ "plain"
    end

    test "rejects a path pointing at a subdirectory of a git repo (not its toplevel)", %{
      tmp: tmp
    } do
      repo = git_repo!(tmp, "widgets")
      subdir = Path.join(repo, "src")
      File.mkdir_p!(subdir)

      registry =
        ProjectRegistry.load(
          projects: [%{name: "widgets_src", path: subdir}],
          config_path: missing_config_path(tmp)
        )

      assert ProjectRegistry.known_projects(registry) == []
    end

    test "one invalid entry does not prevent other valid entries from loading", %{tmp: tmp} do
      good_repo = git_repo!(tmp, "good")
      bad_path = Path.join(tmp, "bad")

      registry =
        ProjectRegistry.load(
          projects: [
            %{name: "good", path: good_repo},
            %{name: "bad", path: bad_path}
          ],
          config_path: missing_config_path(tmp)
        )

      assert ProjectRegistry.known_projects(registry) == ["good"]
      assert {:ok, ^good_repo} = ProjectRegistry.lookup(registry, "good")
    end
  end

  describe "optional override file" do
    test "merges projects defined in the JSON override file", %{tmp: tmp} do
      repo = git_repo!(tmp, "from_file")
      config_path = Path.join(tmp, "projects.json")

      File.write!(
        config_path,
        Jason.encode!([%{"name" => "from_file", "path" => repo, "aliases" => ["ff"]}])
      )

      registry = ProjectRegistry.load(projects: [], config_path: config_path)

      assert {:ok, ^repo} = ProjectRegistry.lookup(registry, "from_file")
      assert {:ok, ^repo} = ProjectRegistry.lookup(registry, "ff")
    end

    test "override file entries take precedence over app config entries with the same name", %{
      tmp: tmp
    } do
      app_repo = git_repo!(tmp, "app_repo")
      file_repo = git_repo!(tmp, "file_repo")
      config_path = Path.join(tmp, "projects.json")

      File.write!(
        config_path,
        Jason.encode!([%{"name" => "shared", "path" => file_repo}])
      )

      registry =
        ProjectRegistry.load(
          projects: [%{name: "shared", path: app_repo}],
          config_path: config_path
        )

      assert {:ok, ^file_repo} = ProjectRegistry.lookup(registry, "shared")
    end

    test "a missing override file is not an error", %{tmp: tmp} do
      repo = git_repo!(tmp, "widgets")

      registry =
        ProjectRegistry.load(
          projects: [%{name: "widgets", path: repo}],
          config_path: missing_config_path(tmp)
        )

      assert {:ok, ^repo} = ProjectRegistry.lookup(registry, "widgets")
    end

    test "a malformed override file is logged and ignored rather than crashing", %{tmp: tmp} do
      repo = git_repo!(tmp, "widgets")
      config_path = Path.join(tmp, "projects.json")
      File.write!(config_path, "not json {{{")

      {registry, log} =
        with_log(fn ->
          ProjectRegistry.load(
            projects: [%{name: "widgets", path: repo}],
            config_path: config_path
          )
        end)

      assert {:ok, ^repo} = ProjectRegistry.lookup(registry, "widgets")
      assert log =~ "projects.json"
    end
  end

  describe "known_projects/1" do
    test "returns the sorted canonical names of all loaded projects", %{tmp: tmp} do
      a = git_repo!(tmp, "alpha")
      b = git_repo!(tmp, "beta")

      registry =
        ProjectRegistry.load(
          projects: [
            %{name: "beta", path: b},
            %{name: "alpha", path: a}
          ],
          config_path: missing_config_path(tmp)
        )

      assert ProjectRegistry.known_projects(registry) == ["alpha", "beta"]
    end
  end
end
