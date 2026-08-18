defmodule ClaudeNotify.MemoryCaptureTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ClaudeNotify.{MemoryCapture, MemoryStore}
  alias ClaudeNotify.ProjectScope.Scope

  setup do
    MemoryStore.clear()
    tmp = Path.join(System.tmp_dir!(), "memory_capture_#{System.unique_integer([:positive])}")
    repo = Path.join(tmp, "repo")
    cwd = Path.join(repo, "apps/web")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(cwd)
    File.mkdir_p!(outside)

    scope = %Scope{
      id: "project_capture",
      name: "capture",
      repo_root: repo,
      cwd: cwd,
      worktree_root: repo,
      git_common_dir: Path.join(repo, ".git")
    }

    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp, repo: repo, cwd: cwd, outside: outside, scope: scope}
  end

  test "captures terminal prompts with redaction and replay safety", %{scope: scope} do
    params = %{
      "event" => "prompt",
      "event_id" => "prompt-1",
      "engine" => "codex",
      "session_id" => "session-1",
      "prompt" => "Use password=hunter2 and Bearer abc.def.ghi"
    }

    session = %{project_scope: scope, engine: "codex"}

    assert {:ok, :inserted, observation} = MemoryCapture.terminal(params, session)
    assert observation.kind == :user_prompt
    assert observation.engine == "codex"
    refute observation.body =~ "hunter2"
    refute observation.body =~ "abc.def.ghi"

    assert {:ok, :duplicate, _} = MemoryCapture.terminal(params, session)
    assert MemoryStore.count() == 1
  end

  test "tool capture keeps only canonical family and safe relative paths", %{
    repo: repo,
    outside: outside,
    scope: scope
  } do
    inside_file = Path.join(repo, "lib/safe.ex")
    outside_file = Path.join(outside, "secret.txt")
    File.mkdir_p!(Path.dirname(inside_file))
    File.write!(inside_file, "safe")
    File.write!(outside_file, "secret")
    File.ln_s!(outside, Path.join(repo, "linked-outside"))

    params = %{
      "event" => "tool_use",
      "event_id" => "tool-1",
      "session_id" => "session-1",
      "tool_name" => "Write",
      "tool_input" => %{
        "file_path" => inside_file,
        "file_paths" => [
          outside_file,
          Path.join(repo, "linked-outside/secret.txt"),
          Path.join(repo, "linked-outside/not-created/deep.txt")
        ]
      },
      "tool_output" => "password=must-not-be-stored"
    }

    assert {:ok, :inserted, observation} =
             MemoryCapture.terminal(params, %{project_scope: scope, engine: "claude"})

    assert observation.body == ""
    assert observation.source_event_id == "tool-1"
    assert observation.metadata["tool_family"] == "write"
    assert observation.metadata["files"] == ["lib/safe.ex"]
    refute inspect(observation) =~ "must-not-be-stored"
    refute inspect(observation) =~ outside_file
  end

  test "file path count follows the configured collection bound", %{repo: repo, scope: scope} do
    previous_memory = Application.get_env(:claude_notify, :memory, %{})

    Application.put_env(
      :claude_notify,
      :memory,
      Map.put(previous_memory, :max_collection_entries, 2)
    )

    on_exit(fn -> Application.put_env(:claude_notify, :memory, previous_memory) end)

    paths =
      for name <- ["one.ex", "two.ex", "three.ex"] do
        path = Path.join(repo, "lib/#{name}")
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, name)
        path
      end

    assert {:ok, :inserted, observation} =
             MemoryCapture.terminal(
               %{
                 "event" => "tool_use",
                 "event_id" => "bounded-files",
                 "session_id" => "session-files",
                 "tool_name" => "Read",
                 "tool_input" => %{"file_paths" => paths}
               },
               %{project_scope: scope, engine: "claude"}
             )

    assert observation.metadata["files"] == ["lib/one.ex", "lib/two.ex"]
  end

  test "shell arguments and output are not retained", %{scope: scope} do
    params = %{
      "event" => "tool_use",
      "event_id" => "shell-1",
      "session_id" => "session-1",
      "tool_name" => "Bash",
      "tool_input" => %{"command" => "curl -H Bearer-secret https://example.com"},
      "tool_output" => "API_KEY=secret-value"
    }

    assert {:ok, :inserted, observation} =
             MemoryCapture.terminal(params, %{project_scope: scope, engine: "claude"})

    assert observation.body == ""

    assert observation.metadata == %{
             "files" => [],
             "outcome" => "completed",
             "tool_family" => "shell"
           }

    refute inspect(observation) =~ "curl"
    refute inspect(observation) =~ "secret-value"
  end

  test "unresolved sessions and unsupported events are skipped", %{scope: scope} do
    long_id = String.duplicate("s", 120)

    log =
      capture_log(fn ->
        assert {:skipped, :unresolved_project_scope} =
                 MemoryCapture.terminal(%{"event" => "prompt", "session_id" => long_id}, %{})
      end)

    assert log =~ String.duplicate("s", 80)
    refute log =~ String.duplicate("s", 81)

    assert {:skipped, :unsupported_event} =
             MemoryCapture.terminal(
               %{"event" => "future", "session_id" => "s"},
               %{project_scope: scope}
             )

    assert MemoryStore.count() == 0
  end

  test "captures ordered dispatcher events with job and engine identity", %{scope: scope} do
    assert {:ok, :inserted, prompt} =
             MemoryCapture.dispatcher(scope, %{
               kind: :user_prompt,
               sequence: 1,
               job_id: 42,
               engine: "codex",
               body: "Fix it"
             })

    assert {:ok, :inserted, result} =
             MemoryCapture.dispatcher(scope, %{
               kind: :result,
               sequence: 2,
               job_id: 42,
               engine: "codex",
               session_id: "thread-1",
               body: "Done",
               status: :ok
             })

    assert prompt.session_id == "job:42"
    assert prompt.sequence == 1
    assert result.session_id == "thread-1"
    assert result.job_id == 42
    assert Enum.map(MemoryStore.list(job_id: 42), & &1.kind) == [:user_prompt, :result]
  end
end
