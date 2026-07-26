defmodule ClaudeNotify.Engine.Codex do
  @moduledoc """
  `ClaudeNotify.Engine` implementation for the Codex CLI (`codex exec`).

  Launches `codex exec --experimental-json --sandbox workspace-write
  --ask-for-approval never <prompt>`. As with `ClaudeNotify.Engine.Claude`,
  auto-approving every action is safe ONLY because `JobRunner` always runs
  this with `cwd` set to the job's throwaway git worktree (see
  `ClaudeNotify.WorktreeManager`) - the worktree boundary is the actual
  safety mechanism, and `--sandbox workspace-write` additionally confines
  the *engine's own* filesystem writes to that cwd at the OS level (unlike
  Claude Code, which has no sandbox of its own and relies entirely on the
  worktree boundary).

  ## What's verified, and how

  Codex, unlike Claude Code, was not run for real to confirm its output
  shape (that would cost real API quota - out of scope for this story). Two
  free, local sources were used instead:

    * `codex --help` / `codex exec --help` / `codex exec resume --help`
      (installed `codex-cli 0.145.0`) - confirms all flag names and enum
      values used below (`--sandbox {read-only,workspace-write,
      danger-full-access}`, `--ask-for-approval {untrusted,on-request,
      never}`), and confirms `resume` does NOT list `--sandbox` or
      `--ask-for-approval` as accepted options.
    * The official `@openai/codex-sdk` JS package, version 0.145.0 - an
      *exact* version match to the installed CLI, bundled locally (read
      from `node_modules/@openai/codex-sdk/dist/index.js` inside another
      local app's `app.asar.unpacked` tree, no network access). This SDK
      spawns `codex exec --experimental-json ...` itself and parses its
      stdout, so its source is a direct, version-locked reference for the
      undocumented `--experimental-json` flag and the event shape it
      produces.

  Two free, local, zero-cost CLI probes (argument-parsing errors only, no
  model ever invoked) confirmed the SDK's flag choices still hold against
  the installed binary:

    * `codex exec --experimental-json --sandbox not-a-real-mode` fails with
      clap's "invalid value ... for '--sandbox'" - i.e. `--experimental-json`
      itself parsed fine; it's a real (if undocumented/"experimental") flag
      on this version.
    * `codex exec resume <id> --sandbox ...` / `--ask-for-approval ...` both
      fail with clap's "unexpected argument" - resume genuinely does not
      accept either flag (it presumably inherits them from the original
      session), while `codex exec resume <id> --experimental-json` parses
      fine and reaches normal prompt handling.

  `--experimental-json` was chosen over the documented, stable `--json` flag
  because it is the more structured of the two: `--json` streams Codex's
  low-level internal protocol events (`task_started`, `exec_command_begin`,
  `agent_reasoning_delta`, `token_count`, ...), while `--experimental-json`
  streams a higher-level "thread/item/turn" shape analogous to Claude Code's
  content blocks (`thread.started`, `item.completed` wrapping a typed
  `item`, `turn.completed`, `turn.failed`). Being "experimental" is a real
  risk worth flagging: the flag's name signals upstream may change or
  remove it in a future `codex-cli` release, unlike `--json`.

  ## `--experimental-json` shape

  Verified from the SDK source (`src/thread.ts` / `src/exec.ts` in
  `@openai/codex-sdk@0.145.0`):

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

  NOT verified - modeled by analogy, since the SDK only ever branches on
  `item.type == "agent_message"` and otherwise treats `item` as an opaque
  blob it stores unread:

    * an `item.completed` event whose `item.type` is anything other than
      `"agent_message"` (e.g. a command execution, file change, or
      reasoning item) is mapped to `:tool_use` with the item's `"type"` as
      the tool name and the whole item map as `input`. The real field names
      Codex uses for these item kinds have not been confirmed against a
      live run.
    * whether `turn.completed`/`turn.failed` themselves repeat `thread_id`
      is unconfirmed either way (the SDK never reads it there, since it
      already captured it from `thread.started`); this module does not
      assume they do - see the note on `thread.started` below.

  ## Why `thread.started` is surfaced as a `:result` event

  `JobRunner.process_line/2` only threads an engine's session/thread id
  into `JobStore` when it sees a `{:result, %{session_id: id}}` event (see
  `maybe_store_session_id/2`) - and receiving one is purely informational
  to `JobRunner`: only the port's `:exit_status` message ever changes a
  job's status. Codex reports identity (`thread.started`, at turn start)
  and outcome (`turn.completed`/`turn.failed`, at turn end) as two separate
  events, unlike Claude Code's `result` event which carries both at once.
  To get the durable thread id captured before assuming anything about
  `turn.completed`'s payload, `thread.started` is surfaced here as an early
  `:result` event: `status: :ok` is a neutral placeholder (not a claim that
  the turn has succeeded) and `summary: nil`. The turn's real outcome is
  reported by a second `:result` event, from `turn.completed`/`turn.failed`,
  with `session_id: nil` (a no-op for `maybe_store_session_id/2`, which
  already holds the id from the first event).
  """

  @behaviour ClaudeNotify.Engine

  @impl true
  def build_command(prompt, _opts) do
    {"codex",
     [
       "exec",
       "--experimental-json",
       "--sandbox",
       "workspace-write",
       "--ask-for-approval",
       "never",
       prompt
     ]}
  end

  @impl true
  def resume_command(session_id, prompt, _opts) do
    {"codex", ["exec", "resume", session_id, "--experimental-json", prompt]}
  end

  @impl true
  def parse_event(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, decoded} -> parse_decoded(decoded)
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp parse_decoded(%{"type" => "thread.started", "thread_id" => thread_id}) do
    {:ok, {:result, %{session_id: thread_id, status: :ok, summary: nil}}}
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
