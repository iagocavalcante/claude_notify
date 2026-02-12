#!/usr/bin/env bash
# Claude Code UserPromptSubmit hook - sends prompt events to claude_notify
# Runs curl in background to avoid blocking Claude Code

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

# Escape JSON special characters
PROMPT=$(echo "$PROMPT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')

curl -s -X POST http://localhost:4040/api/events \
  -H "Content-Type: application/json" \
  -d "{\"event\":\"prompt\",\"session_id\":\"${SESSION_ID}\",\"prompt\":${PROMPT},\"working_dir\":\"${WORKING_DIR}\",\"term_session_id\":\"${TERM_SID}\",\"tty_path\":\"${TTY_PATH}\"}" \
  --connect-timeout 2 \
  --max-time 3 \
  > /dev/null 2>&1

exit 0
