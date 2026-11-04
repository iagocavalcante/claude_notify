defmodule ClaudeNotify.TerminalInjectorTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.TerminalInjector

  @unlocked "<dict></dict>"
  @locked "<key>CGSSessionScreenIsLocked</key><true/>"

  # Records every command and answers ioreg with the given lock state.
  defp opts(overrides \\ []) do
    test = self()
    ioreg = Keyword.get(overrides, :ioreg, @unlocked)
    tmux_result = Keyword.get(overrides, :tmux_result, {"", 0})

    [
      resolve_tmux: fn -> "/bin/tmux" end,
      cmd_runner: fn
        "ioreg", _args, _opts ->
          {ioreg, 0}

        cmd, args, _opts ->
          send(test, {:cmd, cmd, args})
          if cmd == "/bin/tmux", do: tmux_result, else: {"", 0}
      end
    ]
  end

  test "tmux text is pasted via a unique buffer, then Enter" do
    session = %{tmux_pane: "%3", tty_path: "/dev/ttys001"}

    assert :ok = TerminalInjector.send_text(session, "-n line1\nline2", opts())

    assert_received {:cmd, "/bin/tmux", ["set-buffer", "-b", buffer, "--", "-n line1\nline2"]}
    assert buffer =~ ~r/^claude_notify_\d+$/
    assert_received {:cmd, "/bin/tmux", ["paste-buffer", "-b", ^buffer, "-d", "-p", "-t", "%3"]}
    assert_received {:cmd, "/bin/tmux", ["send-keys", "-t", "%3", "Enter"]}
    refute_received {:cmd, "osascript", _}
  end

  test "tmux text honours the socket on every command" do
    session = %{tmux_pane: "%3", tmux_socket: "/tmp/tmux-501/default"}
    assert :ok = TerminalInjector.send_text(session, "hi", opts())

    for sub <- ["set-buffer", "paste-buffer", "send-keys"] do
      assert_received {:cmd, "/bin/tmux", ["-S", "/tmp/tmux-501/default", ^sub | _]}
    end
  end

  test "tmux honours the socket path" do
    session = %{tmux_pane: "%3", tmux_socket: "/tmp/tmux-501/default"}

    assert :ok = TerminalInjector.send_response(session, "yes", opts())

    assert_received {:cmd, "/bin/tmux",
                     ["-S", "/tmp/tmux-501/default", "send-keys", "-t", "%3", "-l", "--", "y"]}
  end

  test "tmux escape uses the Escape key" do
    assert :ok = TerminalInjector.send_response(%{tmux_pane: "%3"}, "escape", opts())
    assert_received {:cmd, "/bin/tmux", ["send-keys", "-t", "%3", "Escape"]}
  end

  test "invalid pane is rejected without running a command" do
    assert {:error, :no_target} = TerminalInjector.send_text(%{tmux_pane: "%3; rm"}, "x", opts())
    assert {:error, :no_target} = TerminalInjector.send_text(%{tmux_pane: "3"}, "x", opts())
    assert {:error, :no_target} = TerminalInjector.send_text(%{}, "x", opts())
    assert {:error, :no_target} = TerminalInjector.send_text(nil, "x", opts())
    refute_received {:cmd, _, _}
  end

  test "invalid socket is rejected without running a command" do
    session = %{tmux_pane: "%3", tmux_socket: "/tmp/../etc/x"}
    assert {:error, :invalid_tmux_socket} = TerminalInjector.send_text(session, "x", opts())
    refute_received {:cmd, _, _}
  end

  test "tmux not found" do
    opts = Keyword.put(opts(), :resolve_tmux, fn -> nil end)
    assert {:error, :tmux_not_found} = TerminalInjector.send_text(%{tmux_pane: "%3"}, "x", opts)
    refute_received {:cmd, _, _}
  end

  test "tmux non-zero exit is reported" do
    opts = opts(tmux_result: {"can't find pane: %3", 1})

    assert {:error, {:tmux_failed, 1, "can't find pane: %3"}} =
             TerminalInjector.send_text(%{tmux_pane: "%3"}, "x", opts)

    refute_received {:cmd, "/bin/tmux", ["paste-buffer" | _]}
  end

  test "Terminal.app backend refuses to run osascript while locked" do
    session = %{tty_path: "/dev/ttys001"}

    assert {:error, :screen_locked} =
             TerminalInjector.send_text(session, "x", opts(ioreg: @locked))

    assert {:error, :screen_locked} =
             TerminalInjector.send_response(session, "yes", opts(ioreg: @locked))

    refute_received {:cmd, "osascript", _}
  end

  test "Terminal.app backend runs osascript while unlocked" do
    assert :ok = TerminalInjector.send_text(%{tty_path: "/dev/ttys001"}, "x", opts())
    assert_received {:cmd, "osascript", ["-e", _script, "/dev/ttys001", "x"]}
  end

  test "tmux works while the screen is locked" do
    assert :ok = TerminalInjector.send_text(%{tmux_pane: "%3"}, "x", opts(ioreg: @locked))
  end
end
