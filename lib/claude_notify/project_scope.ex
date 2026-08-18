defmodule ClaudeNotify.ProjectScope.Scope do
  @moduledoc """
  Canonical identity for one registered project checkout.

  `repo_root` is the registered checkout, while `worktree_root` is the checkout
  containing the current cwd. Both a main checkout and any linked worktree use
  the same `id`, derived from Git's canonical common directory.
  """

  @enforce_keys [:id, :name, :repo_root, :cwd, :worktree_root, :git_common_dir]
  defstruct [:id, :name, :repo_root, :cwd, :worktree_root, :git_common_dir]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          repo_root: String.t(),
          cwd: String.t(),
          worktree_root: String.t(),
          git_common_dir: String.t()
        }
end

defmodule ClaudeNotify.ProjectScope do
  @moduledoc """
  Resolves terminal and dispatcher paths to one registered logical project.

  The resolver compares Git common directories instead of directory basenames.
  Consequently a repository root, any directory below it, and linked worktrees
  all share one identity, while unrelated repositories with the same basename
  remain distinct.

  The supervised process keeps a validated `ProjectRegistry` snapshot so hot
  lifecycle paths do not recursively scan workspace roots for every tool event.
  `reload/1` refreshes that snapshot, and the pure `resolve/2` and
  `for_project/2` forms accept an explicit registry for tests and callers that
  already own a fresh registry.
  """

  use GenServer

  alias ClaudeNotify.ProjectRegistry
  alias ClaudeNotify.ProjectScope.Scope

  @type resolve_error ::
          :invalid_cwd
          | :not_git_repository
          | :resolver_unavailable
          | :unregistered_project
          | {:ambiguous_project, [String.t()]}
          | {:unknown_project, String.t(), [String.t()]}

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc "Resolves a cwd through the supervised registry snapshot."
  @spec resolve(String.t()) :: {:ok, Scope.t()} | {:error, resolve_error()}
  def resolve(cwd) do
    safe_call({:resolve, cwd})
  end

  @doc "Pure resolver using an explicit registry."
  @spec resolve(String.t(), ProjectRegistry.t()) ::
          {:ok, Scope.t()} | {:error, resolve_error()}
  def resolve(cwd, %ProjectRegistry{} = registry) do
    resolve_with_catalog(cwd, build_catalog(registry))
  end

  @doc "Resolves a registered canonical name or alias through the supervised snapshot."
  @spec for_project(String.t()) :: {:ok, Scope.t()} | {:error, resolve_error()}
  def for_project(name) do
    safe_call({:for_project, name})
  end

  @doc "Pure project-name resolver using an explicit registry."
  @spec for_project(ProjectRegistry.t(), String.t()) ::
          {:ok, Scope.t()} | {:error, resolve_error()}
  def for_project(%ProjectRegistry{} = registry, name) when is_binary(name) do
    with {:ok, %{name: canonical_name, path: path}} <- ProjectRegistry.resolve(registry, name),
         {:ok, git} <- git_identity(path) do
      {:ok, scope(canonical_name, git, git, git.worktree_root)}
    end
  end

  @doc "Returns the registry snapshot owned by the supervised resolver."
  @spec registry() :: ProjectRegistry.t()
  def registry do
    GenServer.call(__MODULE__, :registry)
  end

  @doc "Replaces the registry snapshot and rebuilds its canonical Git catalog."
  @spec reload(ProjectRegistry.t()) :: :ok
  def reload(%ProjectRegistry{} = registry) do
    GenServer.call(__MODULE__, {:reload, registry})
  end

  @doc "Returns the canonical name stored on a session, with legacy fallback."
  @spec display_name(map()) :: String.t()
  def display_name(%{project_scope: %Scope{name: name}}), do: name
  def display_name(%{project_scope: %{name: name}}) when is_binary(name), do: name

  # Sessions persisted before ProjectScope existed have no resolved scope.
  # Keep their established UI label until a new event refreshes the record.
  def display_name(%{working_dir: dir}) when is_binary(dir) and dir != "unknown",
    do: Path.basename(dir)

  def display_name(_session), do: "unknown"

  # -- GenServer --

  @impl true
  def init(opts) do
    registry = Keyword.get_lazy(opts, :registry, &ProjectRegistry.load/0)
    {:ok, state_for(registry)}
  end

  @impl true
  def handle_call({:resolve, cwd}, _from, state) do
    {:reply, resolve_with_catalog(cwd, state.catalog), state}
  end

  @impl true
  def handle_call({:for_project, name}, _from, state) do
    {:reply, for_project(state.registry, name), state}
  end

  @impl true
  def handle_call(:registry, _from, state), do: {:reply, state.registry, state}

  @impl true
  def handle_call({:reload, registry}, _from, _state) do
    {:reply, :ok, state_for(registry)}
  end

  # -- Resolution --

  defp state_for(registry), do: %{registry: registry, catalog: build_catalog(registry)}

  # Project identity is additive to notifications and job validation. A
  # resolver restart must become an explicit no-scope result, never an exit
  # that takes the caller down with it.
  defp safe_call(message) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :resolver_unavailable}

      pid ->
        GenServer.call(pid, message)
    end
  catch
    :exit, _reason -> {:error, :resolver_unavailable}
  end

  defp build_catalog(registry) do
    registry
    |> ProjectRegistry.entries()
    |> Enum.flat_map(fn entry ->
      case git_identity(entry.path) do
        {:ok, git} -> [%{name: entry.name, git: git}]
        {:error, _reason} -> []
      end
    end)
  end

  defp resolve_with_catalog(cwd, catalog) do
    with :ok <- validate_cwd(cwd),
         {:ok, current_git} <- git_identity(cwd) do
      exact = Enum.filter(catalog, &(&1.git.worktree_root == current_git.worktree_root))

      candidates =
        case exact do
          [] -> Enum.filter(catalog, &(&1.git.common_dir == current_git.common_dir))
          matches -> matches
        end

      case candidates do
        [%{name: name, git: registered_git}] ->
          {:ok, scope(name, registered_git, current_git, physical_path(cwd))}

        [] ->
          {:error, :unregistered_project}

        matches ->
          names = matches |> Enum.map(& &1.name) |> Enum.sort()
          {:error, {:ambiguous_project, names}}
      end
    end
  end

  defp scope(name, registered_git, current_git, cwd) do
    %Scope{
      id: project_id(registered_git.common_dir),
      name: name,
      repo_root: registered_git.worktree_root,
      cwd: cwd,
      worktree_root: current_git.worktree_root,
      git_common_dir: current_git.common_dir
    }
  end

  defp project_id(common_dir) do
    digest = :crypto.hash(:sha256, common_dir) |> Base.encode16(case: :lower)
    "project_" <> binary_part(digest, 0, 20)
  end

  defp validate_cwd(cwd) when is_binary(cwd) do
    if Path.type(cwd) == :absolute and File.dir?(cwd), do: :ok, else: {:error, :invalid_cwd}
  end

  defp validate_cwd(_cwd), do: {:error, :invalid_cwd}

  defp git_identity(path) do
    with {:ok, worktree_root} <- git_value(path, ["rev-parse", "--show-toplevel"]),
         {:ok, common_dir} <- git_value(path, ["rev-parse", "--git-common-dir"]) do
      canonical_cwd = physical_path(path)
      canonical_worktree = physical_path(worktree_root)

      canonical_common =
        common_dir
        |> expand_git_path(canonical_cwd)
        |> physical_path()

      {:ok, %{worktree_root: canonical_worktree, common_dir: canonical_common}}
    else
      _ -> {:error, :not_git_repository}
    end
  end

  defp git_value(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      _ -> {:error, :git_failed}
    end
  rescue
    _ -> {:error, :git_failed}
  end

  defp expand_git_path(path, worktree_root) do
    if Path.type(path) == :absolute, do: path, else: Path.expand(path, worktree_root)
  end

  # `pwd -P` provides the same physical-path semantics as Git on macOS,
  # including the `/tmp` -> `/private/tmp` ancestor symlink.
  defp physical_path(path) do
    case System.cmd("pwd", ["-P"], cd: path, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> Path.expand(path)
    end
  rescue
    _ -> Path.expand(path)
  end
end
