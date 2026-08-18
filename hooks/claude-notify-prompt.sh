#!/usr/bin/env bash
# Claude Code / Codex UserPromptSubmit hook - sends prompt events to claude_notify

source "$(dirname "$0")/claude-notify-common.sh"

INPUT=$(cat)

SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
PROMPT="${CLAUDE_PROMPT:-}"
WORKING_DIR="${CLAUDE_WORKING_DIRECTORY:-$(pwd)}"
TERM_SID="${TERM_SESSION_ID:-unknown}"
TTY_PATH="$(resolve_terminal_tty)"
[ "$TTY_PATH" = "unknown" ] && exit 0

# Codex provides the values on stdin; Claude also provides the same fields on
# recent versions, with the environment variables retained as fallbacks.
PAYLOAD=$(echo "$INPUT" | python3 -c '
import json, sys, time, uuid
d = json.load(sys.stdin)
out = {
    "event": "prompt",
    "event_id": d.get("event_id") or d.get("hook_event_id") or str(uuid.uuid4()),
    "observed_at": int(time.time() * 1000),
    "engine": sys.argv[6],
    "session_id": d.get("session_id", sys.argv[1]),
    "prompt": d.get("prompt", sys.argv[2])[:500],
    "working_dir": d.get("cwd", sys.argv[3]),
    "term_session_id": sys.argv[4],
    "tty_path": sys.argv[5]
}
print(json.dumps(out))
' "$SESSION_ID" "$PROMPT" "$WORKING_DIR" "$TERM_SID" "$TTY_PATH" "${CLAUDE_NOTIFY_ENGINE:-claude}" 2>/dev/null)

post_event_payload "$PAYLOAD"

exit 0
