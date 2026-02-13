defmodule ClaudeNotify.TerminalInjector do
  @moduledoc """
  Injects keystrokes into a Terminal.app tab identified by its TTY path.
  Uses AppleScript via osascript to find the matching tab and type into it.
  """

  require Logger

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
    case Map.get(@response_keys, response) do
      nil ->
        Logger.warning("TerminalInjector: unknown response #{inspect(response)}")
        {:error, :unknown_response}

      :escape ->
        send_escape_key(tty_path)

      key ->
        send_keystroke(tty_path, key)
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
    # Sanitize text for AppleScript - escape backslashes and quotes
    safe_text =
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    script = type_text_applescript(tty_path, safe_text)
    run_osascript(script)
  end

  def send_text(nil, _text) do
    Logger.warning("TerminalInjector: no tty_path available")
    {:error, :no_tty}
  end

  defp send_keystroke(tty_path, key) do
    script = keystroke_applescript(tty_path, key)
    run_osascript(script)
  end

  defp send_escape_key(tty_path) do
    script = escape_applescript(tty_path)
    run_osascript(script)
  end

  defp find_and_activate_tab(tty_path) do
    """
    tell application "Terminal"
      set targetTab to missing value
      set targetWindow to missing value
      repeat with w in every window
        repeat with t in every tab of w
          if tty of t is "#{tty_path}" then
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
    """
  end

  defp keystroke_applescript(tty_path, key) do
    """
    #{find_and_activate_tab(tty_path)}
        tell application "System Events"
          tell process "Terminal"
            keystroke "#{key}"
            delay 0.05
            keystroke return
          end tell
        end tell
      else
        error "No Terminal tab found with tty #{tty_path}"
      end if
    end tell
    """
  end

  defp type_text_applescript(tty_path, text) do
    """
    #{find_and_activate_tab(tty_path)}
        tell application "System Events"
          tell process "Terminal"
            keystroke "#{text}"
            delay 0.05
            keystroke return
          end tell
        end tell
      else
        error "No Terminal tab found with tty #{tty_path}"
      end if
    end tell
    """
  end

  defp escape_applescript(tty_path) do
    """
    #{find_and_activate_tab(tty_path)}
        tell application "System Events"
          tell process "Terminal"
            key code 53
          end tell
        end tell
      else
        error "No Terminal tab found with tty #{tty_path}"
      end if
    end tell
    """
  end

  defp run_osascript(script) do
    case System.cmd("osascript", ["-e", script], stderr_to_stdout: true) do
      {_output, 0} ->
        Logger.info("TerminalInjector: keystroke sent successfully")
        :ok

      {output, code} ->
        Logger.error("TerminalInjector: osascript failed (exit #{code}): #{output}")
        {:error, {:osascript_failed, code, output}}
    end
  end
end
