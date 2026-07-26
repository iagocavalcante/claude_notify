defmodule ClaudeNotify.JobTranscript do
  @moduledoc """
  In-memory, bounded transcript of a running job's engine output -
  assistant text and file-touching tool calls (the latter enriched with a
  per-file `git diff` captured at the moment the tool ran) - so a watching
  process (the Telegram poller, in a later story) can render what a job is
  actually doing while it runs.

  ## Lifecycle and cleanup

  This is a single, long-lived GenServer supervised once under
  `ClaudeNotify.Application` (like `ClaudeNotify.JobStore` or
  `ClaudeNotify.ActivityTracker`) - not one process per job. That was
  chosen over a per-job named process (Registry) or a raw ETS table because
  this app never has more than a handful of jobs running at once (the
  concurrency cap defaults to 3, see `ClaudeNotify.JobSupervisor`), so a
  single `GenServer.call` per read is not a throughput concern, and it
  keeps this module's test-isolation story identical to every sibling
  tracker (`start_supervised!({JobTranscript, name: ...})`).

  A job's entries live in this process's state from the first `record/3`
  call until `discard/2` is called for that `job_id` - `ClaudeNotify.JobRunner`
  calls `discard/2` right after handing the final transcript snapshot to its
  `opts[:notifier]` on the job's terminal transition (see `JobRunner`'s
  `notify_completed/2`), so a job's entries never outlive the notifier call
  that needed them. This bounds total memory to (currently-running jobs) +
  (jobs whose `JobRunner` crashed hard enough to skip its own `terminate/2`
  safety net, e.g. a `SIGKILL`) - the latter is a known, accepted gap: this
  module holds no independent reaper, since normal termination (including
  the `JobRunner.terminate/2` safety net for an uncaught exception) always
  reaches `discard/2`.

  Entries are capped per job at `:claude_notify, :job_transcript_max_entries`
  (default 200) - oldest entries drop first. This is a count-based bound,
  independent of the per-diff byte cap
  (`:claude_notify, :job_transcript_max_diff_bytes`, default 4000, see
  `tool_use_entry/3`).
  """

  use GenServer
  require Logger

  @default_max_entries 200
  @default_max_diff_bytes 4_000

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc "Appends `entry` to `job_id`'s transcript, evicting the oldest entry if over the configured cap."
  def record(pid \\ __MODULE__, job_id, entry) do
    GenServer.cast(pid, {:record, job_id, entry})
  end

  @doc """
  Reads `job_id`'s current transcript, oldest entry first.

  Pass `last: n` to return only the `n` most recent entries (still oldest
  first). Returns `[]` for a `job_id` with no recorded entries.
  """
  def transcript(pid \\ __MODULE__, job_id, opts \\ []) do
    GenServer.call(pid, {:transcript, job_id, opts})
  end

  @doc "Drops all recorded entries for `job_id`. See the moduledoc for when `JobRunner` calls this."
  def discard(pid \\ __MODULE__, job_id) do
    GenServer.cast(pid, {:discard, job_id})
  end

  @doc "Builds a `:text` transcript entry for an assistant text event."
  def text_entry(text) do
    %{type: :text, text: text, at: now_ms()}
  end

  @doc """
  Builds a `:tool_use` transcript entry for `name`/`input` (the same shape
  `ClaudeNotify.Engine`'s `:tool_use` event carries).

  `worktree_path` is the job's worktree (its `cwd` at the moment the tool
  ran) - used as `git diff`'s `cd:` to capture a per-file diff. A file path
  is extracted defensively from `input` (see `extract_file_path/1`); when
  none is found, or when `worktree_path` is `nil`, or when diff capture
  itself fails (bad path, `git` error, not a repo, ...), `diff:` is `nil`
  and the entry is still recorded - this never raises.
  """
  def tool_use_entry(name, input, worktree_path) do
    file_path = extract_file_path(input)

    %{
      type: :tool_use,
      name: name,
      file_path: file_path,
      diff: maybe_capture_diff(file_path, worktree_path),
      at: now_ms()
    }
  end

  defp now_ms, do: System.system_time(:millisecond)

  # -- Server callbacks --

  @impl true
  def init(opts) do
    max_entries =
      Keyword.get_lazy(opts, :max_entries, fn ->
        Application.get_env(:claude_notify, :job_transcript_max_entries, @default_max_entries)
      end)

    {:ok, %{jobs: %{}, max_entries: max_entries}}
  end

  @impl true
  def handle_cast({:record, job_id, entry}, state) do
    # Newest entry consed to the front; Enum.take/2 on a newest-first list
    # keeps the most recent `max_entries` and drops the (oldest) tail.
    entries = [entry | Map.get(state.jobs, job_id, [])] |> Enum.take(state.max_entries)
    {:noreply, put_in(state, [:jobs, job_id], entries)}
  end

  @impl true
  def handle_cast({:discard, job_id}, state) do
    {:noreply, %{state | jobs: Map.delete(state.jobs, job_id)}}
  end

  @impl true
  def handle_call({:transcript, job_id, opts}, _from, state) do
    entries = Map.get(state.jobs, job_id, [])

    result =
      case Keyword.get(opts, :last) do
        nil -> entries
        n when is_integer(n) and n >= 0 -> Enum.take(entries, n)
      end
      |> Enum.reverse()

    {:reply, result, state}
  end

  # -- File path extraction --

  # Claude Code's Read/Write/Edit tool_use input carries "file_path"
  # (confirmed in ClaudeNotify.Engine.Claude); Codex's item maps are opaque
  # (unconfirmed schema, see ClaudeNotify.Engine.Codex) so a generic "path"
  # key is also accepted as a defensive fallback. Anything else - no
  # extractable path - degrades to a transcript entry with no diff, not a
  # crash.
  defp extract_file_path(input) when is_map(input) do
    case input["file_path"] || input["path"] do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  defp extract_file_path(_input), do: nil

  # -- Diff capture --

  defp maybe_capture_diff(nil, _worktree_path), do: nil
  defp maybe_capture_diff(_file_path, nil), do: nil

  defp maybe_capture_diff(file_path, worktree_path) do
    case capture_diff(file_path, worktree_path) do
      {:ok, diff} -> truncate_bytes(diff, max_diff_bytes())
      :error -> nil
    end
  end

  defp max_diff_bytes do
    Application.get_env(:claude_notify, :job_transcript_max_diff_bytes, @default_max_diff_bytes)
  end

  # A tracked file may have no uncommitted changes (the engine already
  # committed) - `git diff` then legitimately returns "", which is recorded
  # as-is (not treated as a capture failure). An untracked (brand new) file
  # has nothing to diff against, so falls back to a full-file "diff" against
  # /dev/null via --no-index.
  defp capture_diff(file_path, worktree_path) do
    if tracked?(file_path, worktree_path) do
      run_git(["diff", "--", file_path], worktree_path, ok_statuses: [0])
    else
      diff_untracked(file_path, worktree_path)
    end
  end

  defp tracked?(file_path, worktree_path) do
    case run_git(["ls-files", "--error-unmatch", "--", file_path], worktree_path,
           ok_statuses: [0]
         ) do
      {:ok, _output} -> true
      :error -> false
    end
  end

  defp diff_untracked(file_path, worktree_path) do
    full_path = Path.expand(file_path, worktree_path)

    if File.regular?(full_path) do
      # --no-index exits 1 when there IS a difference (the normal case for
      # a brand-new file against /dev/null) and 0 when there is none -
      # both are successful captures, not errors.
      run_git(["diff", "--no-index", "--", "/dev/null", file_path], worktree_path,
        ok_statuses: [0, 1]
      )
    else
      :error
    end
  end

  defp run_git(args, cwd, ok_statuses: ok_statuses) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, status} -> if status in ok_statuses, do: {:ok, output}, else: :error
    end
  rescue
    error ->
      Logger.warning(
        "JobTranscript: git #{inspect(args)} in #{inspect(cwd)} failed: #{inspect(error)}"
      )

      :error
  end

  # Bounds diff bytes without ever cutting a UTF-8 codepoint in half (which
  # would produce an invalid, un-renderable binary): trim back byte by byte
  # from the byte-boundary cut until what's left is valid UTF-8 again (at
  # most 3 extra trims, since a UTF-8 codepoint is at most 4 bytes).
  defp truncate_bytes(text, max_bytes) do
    if byte_size(text) <= max_bytes do
      text
    else
      text
      |> binary_part(0, max_bytes)
      |> valid_utf8_prefix()
      |> Kernel.<>("\n... (truncated)")
    end
  end

  defp valid_utf8_prefix(bin) do
    if String.valid?(bin) do
      bin
    else
      valid_utf8_prefix(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end
end
