#!/usr/bin/env bash
# Claude Code Stop hook - sends stop events to claude_notify
# Reads JSON from stdin, extracts session_id, stop reason, and cwd

INPUT=$(cat)

TERM_SID="${TERM_SESSION_ID:-unknown}"
TTY_DEV="$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')"
if [[ "$TTY_DEV" =~ ^ttys[0-9]+$ ]]; then
  TTY_PATH="/dev/$TTY_DEV"
else
  TTY_PATH="unknown"
fi

# Extract all useful fields from stdin JSON
PAYLOAD=$(echo "$INPUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
out = {
    "event": "stop",
    "session_id": d.get("session_id", "unknown"),
    "stop_reason": d.get("stop_reason", d.get("reason", "unknown")),
    "working_dir": d.get("cwd", "unknown"),
    "term_session_id": "'"${TERM_SID}"'",
    "tty_path": "'"${TTY_PATH}"'",
    "transcript_path": d.get("transcript_path", "")
}
print(json.dumps(out))
' 2>/dev/null)

if [ -n "$PAYLOAD" ]; then
  curl -s -X POST http://localhost:4040/api/events \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    --connect-timeout 2 \
    --max-time 3 \
    > /dev/null 2>&1
fi

exit 0
