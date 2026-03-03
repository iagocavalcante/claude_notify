#!/usr/bin/env bash
# Claude Code Stop hook - sends stop events to claude_notify
# Reads JSON from stdin, extracts session_id, stop reason, and cwd

source "$(dirname "$0")/claude-notify-common.sh"

INPUT=$(cat)

TERM_SID="${TERM_SESSION_ID:-unknown}"
TTY_DEV="$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')"
if [[ "$TTY_DEV" =~ ^ttys[0-9]+$ ]]; then
  TTY_PATH="/dev/$TTY_DEV"
else
  TTY_PATH="unknown"
fi

# Extract all useful fields from stdin JSON, passing shell vars as argv
PAYLOAD=$(echo "$INPUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
out = {
    "event": "stop",
    "session_id": d.get("session_id", "unknown"),
    "stop_reason": d.get("stop_reason", d.get("reason", "unknown")),
    "working_dir": d.get("cwd", "unknown"),
    "term_session_id": sys.argv[1],
    "tty_path": sys.argv[2],
    "transcript_path": d.get("transcript_path", "")
}
print(json.dumps(out))
' "$TERM_SID" "$TTY_PATH" 2>/dev/null)

post_event_payload "$PAYLOAD"

exit 0
