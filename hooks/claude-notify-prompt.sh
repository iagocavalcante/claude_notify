#!/usr/bin/env bash
# Claude Code UserPromptSubmit hook - sends prompt events to claude_notify
# Runs curl in background to avoid blocking Claude Code

source "$(dirname "$0")/claude-notify-common.sh"

SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
PROMPT="${CLAUDE_PROMPT:-}"
WORKING_DIR="${CLAUDE_WORKING_DIRECTORY:-$(pwd)}"
TERM_SID="${TERM_SESSION_ID:-unknown}"
TTY_DEV="$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')"
if [[ "$TTY_DEV" =~ ^ttys[0-9]+$ ]]; then
  TTY_PATH="/dev/$TTY_DEV"
else
  TTY_PATH="unknown"
fi

# Truncate prompt to 500 chars to keep payload small
PROMPT="${PROMPT:0:500}"

# Build JSON payload safely using python3 json.dumps for all values
PAYLOAD=$(python3 -c '
import json, sys
out = {
    "event": "prompt",
    "session_id": sys.argv[1],
    "prompt": sys.argv[2],
    "working_dir": sys.argv[3],
    "term_session_id": sys.argv[4],
    "tty_path": sys.argv[5]
}
print(json.dumps(out))
' "$SESSION_ID" "$PROMPT" "$WORKING_DIR" "$TERM_SID" "$TTY_PATH" 2>/dev/null)

post_event_payload "$PAYLOAD"

exit 0
