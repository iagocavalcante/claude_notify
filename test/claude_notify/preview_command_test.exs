defmodule ClaudeNotify.PreviewCommandTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.PreviewCommand

  @moduletag :tmp_dir

  test "uses an explicit argv command without a shell and expands placeholders", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, ".claude-notify.json"),
      Jason.encode!(%{
        "preview" => %{
          "command" => ["python3", "-m", "http.server", "${PORT}", "--bind", "${HOST}"]
        }
      })
    )

    assert {:ok, command} = PreviewCommand.resolve(dir, 41_234)
    assert command.source == :configured
    assert command.args == ["-m", "http.server", "41234", "--bind", "127.0.0.1"]
    assert {"PORT", "41234"} in command.env
  end

  test "detects a Vite package and its package manager", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "pnpm-lock.yaml"), "lockfileVersion: '9.0'\n")

    File.write!(
      Path.join(dir, "package.json"),
      Jason.encode!(%{
        "scripts" => %{"dev" => "vite"},
        "devDependencies" => %{"vite" => "latest"}
      })
    )

    case System.find_executable("pnpm") do
      nil ->
        assert {:error, {:executable_not_found, "pnpm"}} = PreviewCommand.resolve(dir, 41_235)

      path ->
        assert {:ok, command} = PreviewCommand.resolve(dir, 41_235)
        assert command.executable == path
        assert command.args == ["run", "dev", "--host", "127.0.0.1", "--port", "41235"]
    end
  end

  test "falls back to a static file server", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "index.html"), "hello")

    assert {:ok, command} = PreviewCommand.resolve(dir, 41_236)
    assert command.source == :static_html
    assert command.args == ["-m", "http.server", "41236", "--bind", "127.0.0.1"]
  end

  test "returns a useful error for an unknown project type", %{tmp_dir: dir} do
    assert PreviewCommand.resolve(dir, 41_237) == {:error, :preview_command_not_found}
  end
end
