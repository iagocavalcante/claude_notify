defmodule ClaudeNotify.TerminalInjector do
  @moduledoc """
  Delivers Telegram input to a live terminal session. Sessions inside tmux are
  driven with `tmux send-keys` (works while the screen is locked); others are
  driven via AppleScript keystrokes into the Terminal.app tab matching the TTY
  path, which fails fast with `{:error, :screen_locked}` when the Mac is locked.
  """

  require Logger

  alias ClaudeNotify.ScreenLock

  @tty_regex ~r|^/dev/ttys[0-9]+$|
  @tmux_pane_regex ~r|^%[0-9]+$|
  @tmux_fallbacks ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]

  @response_keys %{
    "yes" => "y",
    "yes_dont_ask" => "a",
    "no" => "n",
    "escape" => :escape,
    "opt_1" => "1",
    "opt_2" => "2",
    "opt_3" => "3",
    "opt_4" => "4",
    "opt_5" => "5",
    "opt_6" => "6",
    "opt_7" => "7",
    "opt_8" => "8",
    "opt_9" => "9"
  }

  @doc """
  Sends a response keystroke to the session's terminal.

  `session` is a map with `:tty_path`, `:tmux_pane` and `:tmux_socket`. A valid
  tmux pane wins (works while the screen is locked); otherwise the Terminal.app
  tab matching the TTY is driven via AppleScript.

  `opts` may carry `:cmd_runner`, an injectable `(cmd, args, opts) ->
  {output, exit_code}` (default `System.cmd/3`), and `:resolve_tmux`, a
  zero-arity function returning the tmux executable path or nil.
  """
  def send_response(session, response, opts \\ []) when is_binary(response) do
    with {:ok, target} <- target(session),
         {:ok, action} <- response_action(response) do
      deliver_response(target, action, opts)
    end
  end

  @doc """
  Types arbitrary text into the session's terminal, followed by Enter.
  See `send_response/3` for the session shape and `opts`.
  """
  def send_text(session, text, opts \\ []) when is_binary(text) do
    with {:ok, target} <- target(session) do
      deliver_text(target, text, opts)
    end
  end

  @doc "True for a tmux pane id such as `%3`."
  def valid_tmux_pane?(pane) when is_binary(pane), do: Regex.match?(@tmux_pane_regex, pane)
  def valid_tmux_pane?(_pane), do: false

  @doc "True for an absolute tmux socket path without `..` segments or NUL bytes."
  def valid_tmux_socket?(socket) when is_binary(socket) do
    Path.type(socket) == :absolute and not String.contains?(socket, <<0>>) and
      ".." not in Path.split(socket)
  end

  def valid_tmux_socket?(_socket), do: false

  @doc "True when the session can be driven by either backend."
  def injectable?(session) do
    valid_tmux_pane?(session[:tmux_pane]) or valid_tty?(session[:tty_path])
  end

  defp valid_tty?(tty_path) when is_binary(tty_path), do: Regex.match?(@tty_regex, tty_path)
  defp valid_tty?(_tty_path), do: false

  defp target(session) when is_map(session) do
    pane = session[:tmux_pane]
    socket = session[:tmux_socket]

    cond do
      valid_tmux_pane?(pane) and (is_nil(socket) or valid_tmux_socket?(socket)) ->
        {:ok, {:tmux, pane, socket}}

      valid_tmux_pane?(pane) ->
        Logger.warning("TerminalInjector: invalid tmux_socket #{inspect(socket)}")
        {:error, :invalid_tmux_socket}

      is_binary(session[:tty_path]) ->
        with :ok <- validate_tty_path(session[:tty_path]),
             do: {:ok, {:terminal, session[:tty_path]}}

      true ->
        Logger.warning("TerminalInjector: no tmux pane or tty_path available")
        {:error, :no_target}
    end
  end

  defp target(_session), do: {:error, :no_target}

  defp deliver_response({:tmux, pane, socket}, :escape, opts),
    do: tmux(socket, ["send-keys", "-t", pane, "Escape"], opts)

  defp deliver_response({:tmux, pane, socket}, key, opts),
    do: tmux(socket, ["send-keys", "-t", pane, "-l", "--", key], opts)

  defp deliver_response({:terminal, tty}, :escape, opts),
    do: terminal_app(escape_applescript(), [tty], opts)

  defp deliver_response({:terminal, tty}, key, opts),
    do: terminal_app(keystroke_applescript(), [tty, key], opts)

  defp deliver_text({:tmux, pane, socket}, text, opts) do
    # Bracketed paste keeps embedded newlines from submitting early. The buffer
    # name is unique per call so concurrent sends can't clobber each other.
    buffer = "claude_notify_" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- tmux(socket, ["set-buffer", "-b", buffer, "--", text], opts),
         :ok <- paste_buffer(socket, buffer, pane, opts) do
      tmux(socket, ["send-keys", "-t", pane, "Enter"], opts)
    end
  end

  defp deliver_text({:terminal, tty}, text, opts),
    do: terminal_app(type_text_applescript(), [tty, text], opts)

  defp paste_buffer(socket, buffer, pane, opts) do
    case tmux(socket, ["paste-buffer", "-b", buffer, "-d", "-p", "-t", pane], opts) do
      :ok ->
        :ok

      error ->
        # -d only deletes on success; don't leak the buffer.
        tmux(socket, ["delete-buffer", "-b", buffer], opts)
        error
    end
  end

  defp tmux(socket, args, opts) do
    resolve = Keyword.get(opts, :resolve_tmux, &resolve_tmux/0)

    case resolve.() do
      nil ->
        Logger.error("TerminalInjector: tmux executable not found")
        {:error, :tmux_not_found}

      tmux_path ->
        socket_args = if socket, do: ["-S", socket], else: []

        case run(opts, tmux_path, socket_args ++ args) do
          {_output, 0} ->
            :ok

          {output, status} ->
            Logger.error("TerminalInjector: tmux failed (exit #{status}): #{output}")
            {:error, {:tmux_failed, status, output}}
        end
    end
  end

  # launchd's PATH usually lacks Homebrew, so fall back to the usual prefixes.
  defp resolve_tmux do
    Application.get_env(:claude_notify, :tmux_path) || System.find_executable("tmux") ||
      Enum.find(@tmux_fallbacks, &File.exists?/1)
  end

  defp terminal_app(script, args, opts) do
    if ScreenLock.locked?(cmd_runner(opts)) do
      Logger.warning("TerminalInjector: screen is locked, not sending keystrokes")
      {:error, :screen_locked}
    else
      run_osascript(script, args, opts)
    end
  end

  defp cmd_runner(opts), do: Keyword.get(opts, :cmd_runner, &System.cmd/3)

  defp run(opts, cmd, args), do: cmd_runner(opts).(cmd, args, stderr_to_stdout: true)

  defp type_text_applescript do
    """
    on run argv
      set ttyPath to item 1 of argv
      set inputText to item 2 of argv

      tell application "Terminal"
        set targetTab to missing value
        set targetWindow to missing value
        repeat with w in every window
          repeat with t in every tab of w
            if tty of t is ttyPath then
              set targetTab to t
              set targetWindow to w
            end if
          end repeat
        end repeat

        if targetTab is not missing value then
          set index of targetWindow to 1
          set selected tab of targetWindow to targetTab
          activate
          delay 0.1
        else
          error "No Terminal tab found with tty " & ttyPath
        end if
      end tell

      set oldClipboard to the clipboard
      try
        set the clipboard to inputText
        tell application "System Events"
          tell process "Terminal"
            keystroke "v" using command down
            delay 0.05
            keystroke return
          end tell
        end tell
      on error errMsg number errNum
        set the clipboard to oldClipboard
        error errMsg number errNum
      end try

      set the clipboard to oldClipboard
    end run
    """
  end

  defp keystroke_applescript do
    """
    on run argv
      set ttyPath to item 1 of argv
      set keyChar to item 2 of argv

      tell application "Terminal"
        set targetTab to missing value
        set targetWindow to missing value
        repeat with w in every window
          repeat with t in every tab of w
            if tty of t is ttyPath then
              set targetTab to t
              set targetWindow to w
            end if
          end repeat
        end repeat

        if targetTab is not missing value then
          set index of targetWindow to 1
          set selected tab of targetWindow to targetTab
          activate
          delay 0.1
          tell application "System Events"
            tell process "Terminal"
              keystroke keyChar
              delay 0.05
              keystroke return
            end tell
          end tell
        else
          error "No Terminal tab found with tty " & ttyPath
        end if
      end tell
    end run
    """
  end

  defp escape_applescript do
    """
    on run argv
      set ttyPath to item 1 of argv

      tell application "Terminal"
        set targetTab to missing value
        set targetWindow to missing value
        repeat with w in every window
          repeat with t in every tab of w
            if tty of t is ttyPath then
              set targetTab to t
              set targetWindow to w
            end if
          end repeat
        end repeat

        if targetTab is not missing value then
          set index of targetWindow to 1
          set selected tab of targetWindow to targetTab
          activate
          delay 0.1
          tell application "System Events"
            tell process "Terminal"
              key code 53
            end tell
          end tell
        else
          error "No Terminal tab found with tty " & ttyPath
        end if
      end tell
    end run
    """
  end

  defp run_osascript(script, args, opts) do
    case run(opts, "osascript", ["-e", script] ++ args) do
      {_output, 0} ->
        Logger.info("TerminalInjector: keystroke sent successfully")
        :ok

      {output, code} ->
        Logger.error("TerminalInjector: osascript failed (exit #{code}): #{output}")
        {:error, {:osascript_failed, code, output}}
    end
  end

  defp response_action(response) do
    case Map.get(@response_keys, response) do
      nil ->
        Logger.warning("TerminalInjector: unknown response #{inspect(response)}")
        {:error, :unknown_response}

      action ->
        {:ok, action}
    end
  end

  defp validate_tty_path(tty_path) do
    if String.match?(tty_path, @tty_regex) do
      :ok
    else
      Logger.warning("TerminalInjector: invalid tty_path #{inspect(tty_path)}")
      {:error, :invalid_tty}
    end
  end
end
