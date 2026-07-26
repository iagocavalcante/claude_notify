defmodule ClaudeNotify.JobTranscriptTest do
  use ExUnit.Case, async: false

  alias ClaudeNotify.JobTranscript

  @moduletag :tmp_dir

  defp create_repo(tmp_dir) do
    path = Path.join(tmp_dir, "repo")
    File.mkdir_p!(path)

    {_, 0} = System.cmd("git", ["init", "-q"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: path)
    File.write!(Path.join(path, "tracked.txt"), "line one\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: path)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "initial commit"], cd: path)

    path
  end

  setup do
    name = :"job_transcript_#{System.unique_integer([:positive])}"
    pid = start_supervised!({JobTranscript, name: name})
    %{pid: pid}
  end

  describe "record/3 and transcript/2" do
    test "returns recorded entries in the order they were recorded", %{pid: pid} do
      JobTranscript.record(pid, 1, JobTranscript.text_entry("first"))
      JobTranscript.record(pid, 1, JobTranscript.text_entry("second"))
      JobTranscript.record(pid, 1, JobTranscript.text_entry("third"))

      texts = pid |> JobTranscript.transcript(1) |> Enum.map(& &1.text)
      assert texts == ["first", "second", "third"]
    end

    test "keeps entries per job_id independent", %{pid: pid} do
      JobTranscript.record(pid, 1, JobTranscript.text_entry("job one"))
      JobTranscript.record(pid, 2, JobTranscript.text_entry("job two"))

      assert [%{text: "job one"}] = JobTranscript.transcript(pid, 1)
      assert [%{text: "job two"}] = JobTranscript.transcript(pid, 2)
    end

    test "returns an empty list for a job_id with no entries", %{pid: pid} do
      assert JobTranscript.transcript(pid, 999) == []
    end

    test "transcript/3 with :last returns only the most recent N entries, still in order", %{
      pid: pid
    } do
      for n <- 1..5 do
        JobTranscript.record(pid, 1, JobTranscript.text_entry("entry #{n}"))
      end

      texts = pid |> JobTranscript.transcript(1, last: 2) |> Enum.map(& &1.text)
      assert texts == ["entry 4", "entry 5"]
    end
  end

  describe "ring buffer bound" do
    test "entry count never exceeds the configured max, oldest entries drop first" do
      name = :"job_transcript_bounded_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          Supervisor.child_spec({JobTranscript, name: name, max_entries: 3}, id: name)
        )

      for n <- 1..5 do
        JobTranscript.record(pid, 1, JobTranscript.text_entry("entry #{n}"))
      end

      texts = pid |> JobTranscript.transcript(1) |> Enum.map(& &1.text)
      assert texts == ["entry 3", "entry 4", "entry 5"]
    end

    test "defaults to the :claude_notify, :job_transcript_max_entries app config" do
      previous = Application.get_env(:claude_notify, :job_transcript_max_entries)
      Application.put_env(:claude_notify, :job_transcript_max_entries, 2)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:claude_notify, :job_transcript_max_entries)
          value -> Application.put_env(:claude_notify, :job_transcript_max_entries, value)
        end
      end)

      name = :"job_transcript_default_cfg_#{System.unique_integer([:positive])}"
      pid = start_supervised!(Supervisor.child_spec({JobTranscript, name: name}, id: name))

      for n <- 1..4 do
        JobTranscript.record(pid, 1, JobTranscript.text_entry("entry #{n}"))
      end

      texts = pid |> JobTranscript.transcript(1) |> Enum.map(& &1.text)
      assert texts == ["entry 3", "entry 4"]
    end
  end

  describe "discard/2" do
    test "removes a job's entries so a subsequent transcript/2 call returns empty", %{pid: pid} do
      JobTranscript.record(pid, 1, JobTranscript.text_entry("hello"))
      assert JobTranscript.transcript(pid, 1) != []

      JobTranscript.discard(pid, 1)

      # discard/2 is a cast - synchronize with the GenServer before asserting.
      :sys.get_state(pid)
      assert JobTranscript.transcript(pid, 1) == []
    end
  end

  describe "text_entry/1" do
    test "builds a :text entry carrying the text and a timestamp" do
      entry = JobTranscript.text_entry("hello world")
      assert %{type: :text, text: "hello world", at: at} = entry
      assert is_integer(at)
    end
  end

  describe "tool_use_entry/3" do
    test "carries the tool name, file path, and a git diff for a tracked, edited file", %{
      tmp_dir: tmp_dir
    } do
      repo = create_repo(tmp_dir)
      File.write!(Path.join(repo, "tracked.txt"), "line one\nline two\n")

      entry = JobTranscript.tool_use_entry("Edit", %{"file_path" => "tracked.txt"}, repo)

      assert %{type: :tool_use, name: "Edit", file_path: "tracked.txt", diff: diff, at: at} =
               entry

      assert is_integer(at)
      assert diff =~ "line two"
      assert diff =~ "tracked.txt"
    end

    test "falls back to a full-file diff for an untracked (new) file", %{tmp_dir: tmp_dir} do
      repo = create_repo(tmp_dir)
      File.write!(Path.join(repo, "brand_new.txt"), "fresh content\n")

      entry = JobTranscript.tool_use_entry("Write", %{"file_path" => "brand_new.txt"}, repo)

      assert %{diff: diff} = entry
      assert diff =~ "fresh content"
    end

    test "carries no diff, but still carries the file path, when the file has no uncommitted changes",
         %{tmp_dir: tmp_dir} do
      repo = create_repo(tmp_dir)

      entry = JobTranscript.tool_use_entry("Read", %{"file_path" => "tracked.txt"}, repo)

      assert %{type: :tool_use, name: "Read", file_path: "tracked.txt", diff: ""} = entry
    end

    test "degrades to an entry without a diff, never raises, when the path can't be resolved (bad cwd)" do
      entry =
        JobTranscript.tool_use_entry(
          "Edit",
          %{"file_path" => "whatever.txt"},
          "/nonexistent/worktree"
        )

      assert %{type: :tool_use, name: "Edit", file_path: "whatever.txt", diff: nil} = entry
    end

    test "degrades to an entry without a diff when the tool_use input has no extractable file path",
         %{tmp_dir: tmp_dir} do
      repo = create_repo(tmp_dir)

      entry = JobTranscript.tool_use_entry("Bash", %{"command" => "echo hi"}, repo)

      assert %{type: :tool_use, name: "Bash", file_path: nil, diff: nil} = entry
    end

    test "degrades to an entry without a diff when the worktree path is nil (defensive)" do
      entry = JobTranscript.tool_use_entry("Edit", %{"file_path" => "x.txt"}, nil)

      assert %{type: :tool_use, name: "Edit", file_path: "x.txt", diff: nil} = entry
    end

    test "truncates an oversized diff with an explicit truncation marker, bounded by config", %{
      tmp_dir: tmp_dir
    } do
      previous = Application.get_env(:claude_notify, :job_transcript_max_diff_bytes)
      Application.put_env(:claude_notify, :job_transcript_max_diff_bytes, 50)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:claude_notify, :job_transcript_max_diff_bytes)
          value -> Application.put_env(:claude_notify, :job_transcript_max_diff_bytes, value)
        end
      end)

      repo = create_repo(tmp_dir)
      big_content = String.duplicate("a very long line of text\n", 20)
      File.write!(Path.join(repo, "tracked.txt"), big_content)

      entry = JobTranscript.tool_use_entry("Edit", %{"file_path" => "tracked.txt"}, repo)

      assert %{diff: diff} = entry
      assert diff =~ "... (truncated)"
      assert byte_size(diff) <= 50 + byte_size("\n... (truncated)")
    end

    test "extracts the file path from a generic \"path\" key too (defensive, opaque engine item maps)",
         %{tmp_dir: tmp_dir} do
      repo = create_repo(tmp_dir)

      entry =
        JobTranscript.tool_use_entry("patch", %{"type" => "patch", "path" => "tracked.txt"}, repo)

      assert %{file_path: "tracked.txt"} = entry
    end

    test "does not raise on a non-map input", %{tmp_dir: tmp_dir} do
      repo = create_repo(tmp_dir)
      entry = JobTranscript.tool_use_entry("weird_item", "not a map", repo)

      assert %{type: :tool_use, name: "weird_item", file_path: nil, diff: nil} = entry
    end
  end
end
