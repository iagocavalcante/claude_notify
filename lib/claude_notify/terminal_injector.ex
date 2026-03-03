defmodule ClaudeNotify.TerminalInjector do
  @moduledoc """
  Injects keystrokes into a Terminal.app tab identified by its TTY path.
  Uses AppleScript via osascript to find the matching tab and type into it.
  """

  require Logger
  @tty_regex ~r|^/dev/ttys[0-9]+$|

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
  Sends a response keystroke to the Terminal.app tab matching the given TTY path.
  """
  def send_response(tty_path, response) when is_binary(tty_path) and is_binary(response) do
    with :ok <- validate_tty_path(tty_path),
         {:ok, action} <- response_action(response) do
      case action do
        :escape -> send_escape_key(tty_path)
        key -> send_keystroke(tty_path, key)
      end
    end
  end

  def send_response(nil, _response) do
    Logger.warning("TerminalInjector: no tty_path available")
    {:error, :no_tty}
  end

  @doc """
  Types arbitrary text into the Terminal.app tab matching the given TTY path,
  followed by Enter.
  """
  def send_text(tty_path, text) when is_binary(tty_path) and is_binary(text) do
    with :ok <- validate_tty_path(tty_path) do
      script = type_text_applescript()
      run_osascript(script, [tty_path, text])
    end
  end

  def send_text(nil, _text) do
    Logger.warning("TerminalInjector: no tty_path available")
    {:error, :no_tty}
  end

  defp send_keystroke(tty_path, key) do
    run_osascript(keystroke_applescript(), [tty_path, key])
  end

  defp send_escape_key(tty_path) do
    run_osascript(escape_applescript(), [tty_path])
  end

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

  defp run_osascript(script, args) do
    case System.cmd("osascript", ["-e", script] ++ args, stderr_to_stdout: true) do
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
