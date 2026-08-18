#!/usr/bin/env bash
# Claude Code / Codex Stop hook - sends stop events to claude_notify
# Reads JSON from stdin, extracts session_id, stop reason, and cwd

source "$(dirname "$0")/claude-notify-common.sh"

INPUT=$(cat)

TERM_SID="${TERM_SESSION_ID:-unknown}"
TTY_PATH="$(resolve_terminal_tty)"
[ "$TTY_PATH" = "unknown" ] && exit 0

# Capture git diff for the working directory
WORKING_DIR="${PWD}"
GIT_DIFF=""
if command -v git &>/dev/null && git -C "$WORKING_DIR" rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  GIT_DIFF_STAT=$(git -C "$WORKING_DIR" diff --stat 2>/dev/null | head -20)
  GIT_DIFF_CONTENT=$(git -C "$WORKING_DIR" diff 2>/dev/null | head -200)
  if [ -n "$GIT_DIFF_STAT" ] || [ -n "$GIT_DIFF_CONTENT" ]; then
    GIT_DIFF="${GIT_DIFF_STAT}

${GIT_DIFF_CONTENT}"
  fi
fi

# Extract all useful fields from stdin JSON, passing shell vars as argv
PAYLOAD=$(echo "$INPUT" | python3 -c '
import json, sys, time, uuid
d = json.load(sys.stdin)
out = {
    "event": "stop",
    "event_id": d.get("event_id") or d.get("hook_event_id") or str(uuid.uuid4()),
    "observed_at": int(time.time() * 1000),
    "engine": sys.argv[4],
    "session_id": d.get("session_id", "unknown"),
    "stop_reason": d.get("stop_reason", d.get("reason", "unknown")),
    "working_dir": d.get("cwd", "unknown"),
    "term_session_id": sys.argv[1],
    "tty_path": sys.argv[2],
    "transcript_path": d.get("transcript_path", ""),
    "assistant_response": d.get("last_assistant_message", ""),
    "git_diff": sys.argv[3]
}
print(json.dumps(out))
' "$TERM_SID" "$TTY_PATH" "$GIT_DIFF" "${CLAUDE_NOTIFY_ENGINE:-claude}" 2>/dev/null)

post_event_payload "$PAYLOAD"

exit 0
