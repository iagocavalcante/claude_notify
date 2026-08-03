defmodule ClaudeNotify.ProjectRegistry do
  @moduledoc """
  Resolves a project name or alias to its registered absolute repo path.

  Registered paths are the first security layer for dispatching jobs. The
  registry is loaded from git repositories discovered below configured
  workspace roots, application config (`:claude_notify, :projects`), and an
  optional `~/.claude_notify/projects.json` override file. Every entry is
  validated before it becomes reachable by `lookup/2`:

    * the path must be absolute and exist on disk
    * the path must be the toplevel of a git repository (via
      `git rev-parse --show-toplevel`, so linked worktrees are accepted)

  Entries that fail validation are dropped with a warning log rather than
  raising, so one bad project config doesn't take down every other project.

  This module holds no process state — `load/1` produces an immutable
  registry struct, and `lookup/2` is a pure read against it. Callers that
  need the registry to live across many lookups (e.g. a future Telegram
  command surface) own that lifetime decision themselves.
  """

  require Logger

  @type project_input :: %{
          required(:name) => String.t(),
          required(:path) => String.t(),
          optional(:aliases) => [String.t()]
        }

  @type t :: %__MODULE__{
          projects: %{String.t() => String.t()},
          aliases: %{String.t() => String.t()}
        }

  defstruct projects: %{}, aliases: %{}

  @doc """
  Loads and validates the registry.

  Options:

    * `:projects` - list of project maps (`name`, `path`, optional `aliases`).
      Defaults to `Application.get_env(:claude_notify, :projects, [])`.
    * `:workspace_roots` - directories scanned for Git repositories. Defaults
      to `Application.get_env(:claude_notify, :workspace_roots, [])`.
    * `:workspace_discovery_depth` - maximum depth scanned below each root.
      Defaults to the configured value or `4`.
    * `:config_path` - path to the optional JSON override file. Defaults to
      `~/.claude_notify/projects.json`. Entries in this file take precedence
      over application config entries with the same name.

  Invalid entries (missing/non-git-toplevel paths, malformed override file)
  are logged and excluded rather than raising.
  """
  @spec load(keyword()) :: t()
  def load(opts \\ []) do
    app_entries = Keyword.get(opts, :projects, Application.get_env(:claude_notify, :projects, []))
    config_path = Keyword.get(opts, :config_path, default_config_path())

    workspace_roots =
      Keyword.get(
        opts,
        :workspace_roots,
        Application.get_env(:claude_notify, :workspace_roots, [])
      )

    discovery_depth =
      Keyword.get(
        opts,
        :workspace_discovery_depth,
        Application.get_env(:claude_notify, :workspace_discovery_depth, 4)
      )

    file_entries = load_file_entries(config_path)
    discovered_entries = discover_entries(workspace_roots, discovery_depth)

    # Explicit config beats discovery, and the machine-local JSON file beats
    # application config. This lets discovery provide a zero-config default
    # without taking control away from users who want stable aliases/names.
    (discovered_entries ++ app_entries ++ file_entries)
    |> Enum.map(&normalize_entry/1)
    |> Enum.reject(&is_nil/1)
    |> merge_by_name()
    |> Enum.reduce(%__MODULE__{}, &add_entry/2)
  end

  @doc """
  Looks up a project by its canonical name or one of its aliases.

  Returns `{:ok, path}` on success, or `{:error, {:unknown_project, name, known_names}}`
  for an unregistered name — never raises.
  """
  @spec lookup(t(), String.t()) ::
          {:ok, String.t()} | {:error, {:unknown_project, String.t(), [String.t()]}}
  def lookup(%__MODULE__{} = registry, name) when is_binary(name) do
    canonical = Map.get(registry.aliases, name, name)

    case Map.fetch(registry.projects, canonical) do
      {:ok, path} -> {:ok, path}
      :error -> {:error, {:unknown_project, name, known_projects(registry)}}
    end
  end

  @doc """
  Returns the sorted list of registered canonical project names.
  """
  @spec known_projects(t()) :: [String.t()]
  def known_projects(%__MODULE__{} = registry) do
    registry.projects |> Map.keys() |> Enum.sort()
  end

  @doc """
  Returns canonical project names and their validated paths, sorted by name.

  This is intentionally the only project-listing shape exposed to UI callers;
  Telegram can show a friendly directory while continuing to pass the stable
  canonical name back into `lookup/2`.
  """
  @spec entries(t()) :: [%{name: String.t(), path: String.t()}]
  def entries(%__MODULE__{} = registry) do
    registry.projects
    |> Enum.map(fn {name, path} -> %{name: name, path: path} end)
    |> Enum.sort_by(& &1.name)
  end

  defp default_config_path do
    Path.join(System.user_home!(), ".claude_notify/projects.json")
  end

  defp discover_entries(roots, max_depth) when is_list(roots) and is_integer(max_depth) do
    candidates =
      roots
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()
      |> Enum.flat_map(fn root ->
        if File.dir?(root) do
          canonical_root = physical_path(root)

          root
          |> collect_git_repos(0, max(max_depth, 0), canonical_root)
          |> Enum.map(fn path ->
            %{
              base: Path.basename(path),
              path: path,
              relative: Path.relative_to(path, root),
              root: root
            }
          end)
        else
          Logger.info("ProjectRegistry: workspace root does not exist: #{inspect(root)}")
          []
        end
      end)
      |> Enum.uniq_by(& &1.path)
      |> Enum.sort_by(& &1.path)

    basename_counts = Enum.frequencies_by(candidates, & &1.base)

    candidates
    |> Enum.reduce({[], MapSet.new()}, fn candidate, {entries, used_names} ->
      preferred =
        if Map.fetch!(basename_counts, candidate.base) == 1,
          do: candidate.base,
          else: candidate.relative

      name = unique_name(preferred, candidate, used_names)
      entry = %{name: name, path: candidate.path, aliases: []}
      {[entry | entries], MapSet.put(used_names, name)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp discover_entries(_roots, _max_depth), do: []

  defp collect_git_repos(path, depth, max_depth, canonical_root) do
    cond do
      git_checkout?(path) ->
        [path]

      depth >= max_depth ->
        []

      true ->
        case File.ls(path) do
          {:ok, children} ->
            children
            |> Enum.reject(&ignored_directory?/1)
            |> Enum.map(&Path.join(path, &1))
            |> Enum.filter(&File.dir?/1)
            |> Enum.filter(&within_root?(&1, canonical_root))
            |> Enum.flat_map(&collect_git_repos(&1, depth + 1, max_depth, canonical_root))

          {:error, reason} ->
            Logger.warning(
              "ProjectRegistry: cannot scan workspace directory #{inspect(path)}: #{inspect(reason)}"
            )

            []
        end
    end
  end

  defp git_checkout?(path),
    do: File.dir?(Path.join(path, ".git")) or File.regular?(Path.join(path, ".git"))

  defp within_root?(path, canonical_root) do
    resolved = physical_path(path)
    resolved == canonical_root or String.starts_with?(resolved, canonical_root <> "/")
  end

  @ignored_directories ~w(.git .cache .direnv .elixir_ls _build deps node_modules vendor)
  defp ignored_directory?("." <> _hidden), do: true
  defp ignored_directory?(name), do: name in @ignored_directories

  defp unique_name(preferred, candidate, used_names) do
    cond do
      not MapSet.member?(used_names, preferred) ->
        preferred

      not MapSet.member?(used_names, Path.join(Path.basename(candidate.root), candidate.relative)) ->
        Path.join(Path.basename(candidate.root), candidate.relative)

      true ->
        unique_name_with_suffix(preferred, used_names, 2)
    end
  end

  defp unique_name_with_suffix(preferred, used_names, suffix) do
    candidate = "#{preferred}-#{suffix}"

    if MapSet.member?(used_names, candidate),
      do: unique_name_with_suffix(preferred, used_names, suffix + 1),
      else: candidate
  end

  defp load_file_entries(path) do
    with true <- File.regular?(path),
         {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content) do
      List.wrap(decoded)
    else
      false ->
        []

      {:error, reason} ->
        Logger.warning(
          "ProjectRegistry: could not read override file #{path} (#{inspect(reason)}), ignoring it"
        )

        []
    end
  end

  defp normalize_entry(%{name: name, path: path} = entry) when is_binary(name) do
    %{name: name, path: path, aliases: Map.get(entry, :aliases, [])}
  end

  defp normalize_entry(%{"name" => name, "path" => path} = entry) when is_binary(name) do
    %{name: name, path: path, aliases: Map.get(entry, "aliases", [])}
  end

  defp normalize_entry(other) do
    Logger.warning("ProjectRegistry: dropping malformed project entry #{inspect(other)}")
    nil
  end

  # Later entries win on name collision, so JSON override-file entries
  # (appended after application-config entries in `load/1`) take precedence.
  defp merge_by_name(entries) do
    entries
    |> Enum.reduce(%{}, fn entry, acc -> Map.put(acc, entry.name, entry) end)
    |> Map.values()
  end

  defp add_entry(%{name: name, path: path, aliases: aliases}, registry) do
    case validate_path(name, path) do
      {:ok, resolved} ->
        %{registry | projects: Map.put(registry.projects, name, resolved)}
        |> register_aliases(name, aliases)

      :error ->
        registry
    end
  end

  defp register_aliases(registry, name, aliases) do
    updated_aliases =
      Enum.reduce(List.wrap(aliases), registry.aliases, fn alias, acc ->
        Map.put(acc, alias, name)
      end)

    %{registry | aliases: updated_aliases}
  end

  defp validate_path(name, path) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         true <- File.dir?(path),
         {:ok, toplevel} <- git_toplevel(path),
         true <- physical_path(path) == toplevel do
      {:ok, path}
    else
      _ ->
        Logger.warning(
          "ProjectRegistry: rejecting project #{inspect(name)} at #{inspect(path)} - " <>
            "path is missing or is not a git repository toplevel"
        )

        :error
    end
  end

  defp validate_path(name, path) do
    Logger.warning(
      "ProjectRegistry: rejecting project #{inspect(name)} - invalid path #{inspect(path)}"
    )

    :error
  end

  defp git_toplevel(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      _ -> :error
    end
  end

  # git rev-parse --show-toplevel resolves symlinks in the path (e.g. macOS's
  # /tmp -> /private/tmp), so the configured path must be resolved the same
  # way before comparing - otherwise a real toplevel would be misclassified
  # as "not a toplevel" whenever an ancestor directory is a symlink.
  defp physical_path(path) do
    case System.cmd("pwd", ["-P"], cd: path, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> Path.expand(path)
    end
  end
end
