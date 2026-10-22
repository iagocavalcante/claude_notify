defmodule ClaudeNotify.EngineDoctorTest do
  use ExUnit.Case, async: true
  alias ClaudeNotify.EngineDoctor

  test "missing agents have setup guidance without trying a model" do
    report = EngineDoctor.report(find: fn _ -> nil end)
    assert report =~ "claude: not installed"
    assert report =~ "codex: not installed"
    assert report =~ "/doctor"
  end

  test "diagnostics redact auth output and distinguish unsupported CLI arguments" do
    probe = fn _, args ->
      cond do
        args == ["--version"] -> {"codex-cli 0.163.0 secret-value", 0}
        "status" in args -> {~s({"loggedIn":false,"token":"secret-value"}), 0}
        true -> {"unsupported", 2}
      end
    end

    report = EngineDoctor.report(find: fn engine -> engine end, probe: probe)
    assert report =~ "0.163.0"
    assert report =~ "needs attention"
    assert report =~ "unsupported"
    refute report =~ "secret-value"
  end
end
