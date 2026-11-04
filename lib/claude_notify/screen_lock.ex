defmodule ClaudeNotify.ScreenLock do
  @moduledoc """
  Detects whether the macOS screen is locked. While locked, macOS drops
  synthetic keystrokes, so Terminal.app injection cannot work.
  """

  require Logger

  @locked_regex ~r|<key>CGSSessionScreenIsLocked</key>\s*<true/>|

  @doc """
  True when `ioreg` reports `CGSSessionScreenIsLocked` for the console user.
  The key is absent while unlocked. Detection failures count as unlocked so
  they never block delivery.

  `cmd_runner` is an injectable `(cmd, args, opts) -> {output, exit_code}`.
  """
  def locked?(cmd_runner \\ &System.cmd/3) do
    case cmd_runner.("ioreg", ["-n", "Root", "-d1", "-a"], stderr_to_stdout: true) do
      {output, 0} ->
        Regex.match?(@locked_regex, output)

      {output, code} ->
        Logger.debug("ScreenLock: ioreg failed (exit #{code}): #{output}")
        false
    end
  rescue
    error ->
      Logger.debug("ScreenLock: ioreg unavailable: #{Exception.message(error)}")
      false
  end
end
