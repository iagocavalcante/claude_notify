defmodule ClaudeNotify.ScreenLockTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.ScreenLock

  defp runner(result), do: fn "ioreg", ["-n", "Root", "-d1", "-a"], _opts -> result end

  test "locked when IOConsoleUsers carries CGSSessionScreenIsLocked true" do
    xml = """
    <dict>
      <key>kCGSSessionOnConsoleKey</key>
      <true/>
      <key>CGSSessionScreenIsLocked</key>
      <true/>
    </dict>
    """

    assert ScreenLock.locked?(runner({xml, 0}))
  end

  test "unlocked when the key is absent" do
    xml = "<dict><key>kCGSSessionOnConsoleKey</key><true/></dict>"
    refute ScreenLock.locked?(runner({xml, 0}))
  end

  test "treats ioreg failure as unlocked" do
    refute ScreenLock.locked?(runner({"boom", 1}))
    refute ScreenLock.locked?(fn _, _, _ -> raise ErlangError, original: :enoent end)
  end
end
