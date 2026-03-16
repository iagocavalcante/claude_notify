#!/usr/bin/env bash
# Claude Code Notification hook - sends notification events to claude_notify
# Reads JSON from stdin (contains "message" field with the notification text)

source "$(dirname "$0")/claude-notify-common.sh"

INPUT=$(cat)

SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
TERM_SID="${TERM_SESSION_ID:-unknown}"
TTY_DEV="$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')"
if [[ "$TTY_DEV" =~ ^ttys[0-9]+$ ]]; then
  TTY_PATH="/dev/$TTY_DEV"
else
  TTY_PATH="unknown"
fi

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

# Build payload using python3 - pass shell vars as argv to avoid injection
PAYLOAD=$(echo "$INPUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
out = {
    "event": "notification",
    "session_id": d.get("session_id", sys.argv[1]),
    "message": d.get("message", ""),
    "term_session_id": sys.argv[2],
    "tty_path": sys.argv[3],
    "working_dir": d.get("cwd", sys.argv[4]),
    "transcript_path": d.get("transcript_path", ""),
    "git_diff": sys.argv[5]
}
print(json.dumps(out))
' "$SESSION_ID" "$TERM_SID" "$TTY_PATH" "$PWD" "$GIT_DIFF" 2>/dev/null)

post_event_payload "$PAYLOAD"

exit 0
