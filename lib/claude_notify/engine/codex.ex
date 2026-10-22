defmodule ClaudeNotify.Engine.Codex do
  @moduledoc """
  `ClaudeNotify.Engine` implementation for the Codex CLI (`codex exec`).

  Launches `codex --ask-for-approval never --sandbox workspace-write exec
  --json <prompt>`. The approval and sandbox options precede `exec` so they
  also apply to resumed sessions. `JobRunner` sets the process cwd to the
  app-owned worktree; do not pass `--worktree`, which would create a second
  workspace outside the job's tracked path.

  ## JSONL events

  Uses the documented `--json` stream. Command parsing was checked against
  codex-cli 0.163.0 with `--help`, without invoking a model. Event parsing
  is covered by fixture runs, not a live model run.

    * `{"type":"thread.started","thread_id":"..."}` - one per invocation
      (including resumed ones - the SDK unconditionally re-reads
      `thread_id` off this event even when resuming a known thread),
      carrying the id `resume_command/3` later needs.
    * `{"type":"item.completed","item":{"type":"agent_message","text":"..."}}`
      - a completed agent message; the SDK reads `event.item.text`.
    * `{"type":"turn.completed","usage":{...}}` - the turn finished
      successfully; the SDK reads `event.usage`.
    * `{"type":"turn.failed","error":{"message":"..."}}` - the turn failed;
      the SDK reads `event.error.message`.

  Non-message completed items map to `:tool_use`, retaining the whole item
  as input. Completion events need not repeat the thread id captured at start.

  ## Why `thread.started` is a `:session` event, not a `:result`

  Codex reports identity (`thread.started`, at turn start) and outcome
  (`turn.completed`/`turn.failed`, at turn end) as two separate events,
  unlike Claude Code's `result` event which carries both at once. Rather
  than stretching `:result` to also mean "here's the id, no outcome yet"
  (which would put a misleading `status: :ok` in the event stream before
  the turn has done anything - a real problem for any future consumer of
  these events, e.g. a job-completion report), `thread.started` maps to the
  `Engine` behaviour's dedicated `{:session, session_id}` event instead.
  `turn.completed`/`turn.failed` remain the only `:result` events this
  module emits, each with `session_id: nil` (the id was already captured
  from `:session`) and a real, truthful `status`/`summary`.
  """

  @behaviour ClaudeNotify.Engine

  @impl true
  def build_command(prompt, opts) do
    {"codex",
     model_args(opts) ++
       [
         "--ask-for-approval",
         "never",
         "--sandbox",
         "workspace-write",
         "exec",
         "--json",
         prompt
       ]}
  end

  @impl true
  def resume_command(session_id, prompt, opts) do
    {"codex",
     model_args(opts) ++
       [
         "--ask-for-approval",
         "never",
         "--sandbox",
         "workspace-write",
         "exec",
         "resume",
         session_id,
         "--json",
         prompt
       ]}
  end

  defp model_args(opts) do
    case Keyword.get(opts, :model) do
      nil -> []
      model when is_binary(model) -> ["--model", model]
    end
  end

  @impl true
  def parse_event(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, decoded} -> parse_decoded(decoded)
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp parse_decoded(%{"type" => "thread.started", "thread_id" => thread_id}) do
    {:ok, {:session, thread_id}}
  end

  defp parse_decoded(%{"type" => "item.completed", "item" => %{"type" => "agent_message"} = item}) do
    {:ok, {:text, item["text"]}}
  end

  defp parse_decoded(%{"type" => "item.completed", "item" => %{"type" => item_type} = item}) do
    {:ok, {:tool_use, %{id: item["id"], name: item_type, input: item}}}
  end

  defp parse_decoded(%{"type" => "turn.completed"}) do
    {:ok, {:result, %{session_id: nil, status: :ok, summary: nil}}}
  end

  defp parse_decoded(%{"type" => "turn.failed", "error" => error}) do
    {:ok, {:result, %{session_id: nil, status: :error, summary: error["message"]}}}
  end

  defp parse_decoded(%{"type" => _other}), do: :ignore
  defp parse_decoded(_other), do: :ignore
end
