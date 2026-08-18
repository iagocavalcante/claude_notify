defmodule ClaudeNotify.Engine.Claude do
  @moduledoc """
  `ClaudeNotify.Engine` implementation for the Claude Code CLI.

  Launches `claude -p <wrapped_prompt> --output-format stream-json --verbose
  --dangerously-skip-permissions`, optionally with `--chrome`. Auto-approving every tool call is safe
  ONLY because `JobRunner` always runs this with `cwd` set to the job's
  throwaway git worktree/branch (see `ClaudeNotify.WorktreeManager`), which
  is never pushed automatically - the worktree boundary is the actual
  safety mechanism; `--dangerously-skip-permissions` merely removes the
  interactive prompt that would otherwise block a headless run.

  ## stream-json shape

  Confirmed against a real `claude -p ... --output-format stream-json
  --verbose` invocation (2026-07-25, claude-code 2.1.220, trivial no-tool
  prompt):

    * `{"type":"system","subtype":"init",...,"session_id":"..."}` - session
      start, carries the engine session id.
    * `{"type":"assistant","message":{"content":[{"type":"text","text":"..."}]},...}`
      - assistant text; a `"thinking"` content block was also observed and is
        ignored.
    * `{"type":"result","subtype":"success","is_error":false,"result":"...","session_id":"..."}`
      - final result: `is_error` drives `:ok`/`:error`, `result` is the
        summary.
    * `{"type":"system","subtype":"hook_started"|"hook_response",...}` and
      `{"type":"rate_limit_event",...}` - engine-internal noise, ignored.

  NOT verified against a live run - the probe prompt never invoked a tool,
  so these are modeled on Claude Code's documented stream-json schema rather
  than observed:

    * an `assistant` message whose content includes a `tool_use` block
      (`{"type":"tool_use","id":...,"name":...,"input":...}`)
    * a `user` message carrying a `tool_result` block (currently mapped to
      `:ignore` - JobRunner has no use for tool results in this story's
      scope)

  Anyone building on `:tool_use` events for real work should confirm this
  shape against a run that actually exercises a tool before depending on it.

  Only the first job-relevant content block of a given `assistant` message is
  turned into an event; the one live capture always emitted one block per
  message, but a message with multiple relevant blocks would silently drop
  everything after the first. Widen this if that turns out to matter.
  """

  @behaviour ClaudeNotify.Engine

  @impl true
  def build_command(prompt, opts) do
    {"claude",
     chrome_args(opts) ++
       [
         "-p",
         prompt,
         "--output-format",
         "stream-json",
         "--verbose",
         "--dangerously-skip-permissions"
       ]}
  end

  @impl true
  def resume_command(session_id, prompt, opts) do
    {"claude",
     chrome_args(opts) ++
       [
         "-p",
         "--resume",
         session_id,
         prompt,
         "--output-format",
         "stream-json",
         "--verbose",
         "--dangerously-skip-permissions"
       ]}
  end

  defp chrome_args(opts) do
    enabled =
      Keyword.get(
        opts,
        :chrome,
        Application.get_env(:claude_notify, :claude_chrome_enabled, false)
      )

    if enabled, do: ["--chrome"], else: []
  end

  @impl true
  def parse_event(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, decoded} -> parse_decoded(decoded)
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp parse_decoded(%{"type" => "result"} = event) do
    status = if event["is_error"], do: :error, else: :ok

    {:ok, {:result, %{session_id: event["session_id"], status: status, summary: event["result"]}}}
  end

  defp parse_decoded(%{"type" => "system", "subtype" => "init", "session_id" => session_id})
       when is_binary(session_id) and session_id != "" do
    {:ok, {:session, session_id}}
  end

  defp parse_decoded(%{"type" => "assistant", "message" => %{"content" => blocks}})
       when is_list(blocks) do
    case Enum.find_value(blocks, &content_block_event/1) do
      nil -> :ignore
      event -> {:ok, event}
    end
  end

  defp parse_decoded(%{"type" => _other}), do: :ignore
  defp parse_decoded(_other), do: :ignore

  defp content_block_event(%{"type" => "text", "text" => text}), do: {:text, text}

  defp content_block_event(%{"type" => "tool_use"} = block) do
    {:tool_use, %{id: block["id"], name: block["name"], input: block["input"]}}
  end

  defp content_block_event(_other), do: nil
end
