defmodule ClaudeNotify.Engine.ModelTest do
  use ExUnit.Case, async: true

  test "both engines forward model selection to fresh and resumed CLI commands" do
    for engine <- [ClaudeNotify.Engine.Claude, ClaudeNotify.Engine.Codex],
        command <- [
          engine.build_command("task", model: "test-model"),
          engine.resume_command("session", "next", model: "test-model")
        ] do
      {_, args} = command
      assert ["--model", "test-model" | _] = args
    end
  end
end
