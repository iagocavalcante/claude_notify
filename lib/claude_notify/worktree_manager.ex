defmodule ClaudeNotify.WorktreeManager.Worktree do
  @moduledoc """
  Identifies a job's isolated git worktree: which repo it was created from,
  which job it belongs to, and where its directory and branch live.
  """

  @enforce_keys [:repo_path, :job_id, :path, :branch]
  defstruct [:repo_path, :job_id, :path, :branch]

  @type t :: %__MODULE__{
          repo_path: String.t(),
          job_id: String.t(),
          path: String.t(),
          branch: String.t()
        }
end

defmodule ClaudeNotify.WorktreeManager do
  @moduledoc """
  Creates and tears down isolated git worktrees for dispatcher jobs.

  Every job gets its own `git worktree` on a fresh branch
  `job/<job_id>-<slug>`, checked out under a dedicated base directory
  (`~/.claude_notify/worktrees/<repo>/<job_id>` by default, configurable via
  `:claude_notify, :worktree_base_dir`). This keeps auto-approved job work
  isolated from the repo's main checkout.

  All git invocations go through `System.cmd/3` with an explicit `cd` and an
  argument list — never a shell string built from user-controlled input.
  """

  require Logger

  alias ClaudeNotify.WorktreeManager.Worktree

  @identifier_regex ~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/

  @doc """
  Creates a worktree for `job_id` in `repo_path`, on a fresh branch
  `job/<job_id>-<slug>` based on the repo's currently checked-out (default)
  branch.

  Returns `{:ok, %Worktree{}}` with the worktree path and branch name, or
  `{:error, reason}`. Calling this twice for the same `job_id` fails cleanly
  with `{:error, :already_exists}` — no worktree or branch is touched.
  """
  def create(repo_path, job_id, slug) do
    worktree_path = worktree_path(repo_path, job_id)
    branch = branch_name(job_id, slug)

    with :ok <- validate_identifier(job_id),
         :ok <- validate_identifier(slug),
         :ok <- ensure_absent(worktree_path),
         {:ok, base_branch} <- default_branch(repo_path),
         {:ok, _output} <-
           git(repo_path, ["worktree", "add", "-b", branch, worktree_path, base_branch]) do
      {:ok,
       %Worktree{
         repo_path: Path.expand(repo_path),
         job_id: job_id,
         path: worktree_path,
         branch: branch
       }}
    end
  end

  @doc """
  Resolves an existing app-owned worktree for a later conversational turn.

  The supplied path and branch must exactly match `git worktree list`; callers
  cannot turn this into arbitrary-directory execution by editing persisted job
  metadata. The returned struct can be passed to `JobRunner` as
  `:existing_worktree`.
  """
  def reuse(repo_path, path, branch)
      when is_binary(repo_path) and is_binary(path) and is_binary(branch) do
    expanded_path = Path.expand(path)

    with true <- File.dir?(expanded_path),
         {:ok, worktrees} <- list(repo_path),
         %Worktree{} = worktree <-
           Enum.find(worktrees, fn worktree ->
             Path.expand(worktree.path) == expanded_path and worktree.branch == branch
           end) do
      {:ok, worktree}
    else
      false -> {:error, :missing_worktree}
      nil -> {:error, :unregistered_worktree}
      {:error, reason} -> {:error, reason}
    end
  end

  def reuse(_repo_path, _path, _branch), do: {:error, :invalid_worktree}

  @doc """
  Discards a job's worktree: removes the worktree directory (forcing past
  any uncommitted changes) and deletes its branch. Idempotent — safe to call
  more than once for the same worktree.
  """
  def discard(%Worktree{repo_path: repo_path, path: path, branch: branch}) do
    with :ok <- remove_worktree(repo_path, path),
         :ok <- delete_branch(repo_path, branch) do
      :ok
    end
  end

  @doc """
  Lists the job worktrees currently registered for `repo_path` — the ones
  living directly under this repo's configured worktree base directory.
  """
  def list(repo_path) do
    with {:ok, output} <- git(repo_path, ["worktree", "list", "--porcelain"]) do
      root = repo_worktree_root(repo_path)
      canonical_root = realpath(root)

      worktrees =
        output
        |> parse_porcelain()
        |> Enum.filter(fn {path, _branch} -> Path.dirname(path) == canonical_root end)
        |> Enum.map(fn {path, branch} ->
          job_id = Path.basename(path)

          %Worktree{
            repo_path: Path.expand(repo_path),
            job_id: job_id,
            path: Path.join(root, job_id),
            branch: branch
          }
        end)

      {:ok, worktrees}
    end
  end

  defp ensure_absent(path) do
    if File.exists?(path), do: {:error, :already_exists}, else: :ok
  end

  defp default_branch(repo_path) do
    with {:ok, output} <- git(repo_path, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      case String.trim(output) do
        "HEAD" -> {:error, :detached_head}
        branch -> {:ok, branch}
      end
    end
  end

  defp remove_worktree(repo_path, path) do
    if File.exists?(path) do
      case git(repo_path, ["worktree", "remove", "--force", path]) do
        {:ok, _output} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp delete_branch(repo_path, branch) do
    if branch_exists?(repo_path, branch) do
      case git(repo_path, ["branch", "-D", branch]) do
        {:ok, _output} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
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

  defp parse_porcelain(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.map(&parse_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_entry(block) do
    lines = String.split(block, "\n", trim: true)

    path =
      Enum.find_value(lines, fn
        "worktree " <> path -> path
        _ -> nil
      end)

    branch =
      Enum.find_value(lines, fn
        "branch refs/heads/" <> branch -> branch
        _ -> nil
      end)

    if path && branch, do: {path, branch}
  end

  defp validate_identifier(value) when is_binary(value) do
    if Regex.match?(@identifier_regex, value) do
      :ok
    else
      Logger.warning("WorktreeManager: rejecting unsafe identifier: #{inspect(value)}")
      {:error, {:invalid_identifier, value}}
    end
  end

  defp validate_identifier(value), do: {:error, {:invalid_identifier, value}}

  defp branch_name(job_id, slug), do: "job/#{job_id}-#{slug}"

  defp worktree_path(repo_path, job_id), do: Path.join(repo_worktree_root(repo_path), job_id)

  defp repo_worktree_root(repo_path) do
    repo_id = repo_path |> Path.expand() |> Path.basename()
    Path.join(worktree_base_dir(), repo_id)
  end

  defp worktree_base_dir do
    Application.get_env(
      :claude_notify,
      :worktree_base_dir,
      Path.join([System.user_home!(), ".claude_notify", "worktrees"])
    )
    |> Path.expand()
  end

  # Fully resolves symlinks in `path`, component by component, so it can be
  # compared against the canonical absolute paths `git worktree list
  # --porcelain` reports (git always resolves symlinked ancestors, e.g.
  # macOS's /tmp -> /private/tmp, even when we didn't).
  defp realpath(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce("/", &resolve_component/2)
  end

  defp resolve_component(segment, resolved_parent) do
    candidate = Path.join(resolved_parent, segment)

    case File.read_link(candidate) do
      {:ok, target} ->
        if Path.type(target) == :absolute do
          realpath(target)
        else
          resolved_parent |> Path.join(target) |> realpath()
        end

      {:error, _not_a_symlink_or_missing} ->
        candidate
    end
  end

  defp git(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, code} ->
        Logger.error(
          "WorktreeManager: git #{Enum.join(args, " ")} failed (exit #{code}): #{output}"
        )

        {:error, {:git_failed, code, output}}
    end
  end
end
