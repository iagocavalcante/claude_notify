#!/usr/bin/env bash
# Claude Code PostToolUse hook - sends tool use events to claude_notify

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

# Extract tool_name, tool_input, and tool_response from stdin JSON
# Pass shell vars as argv to avoid injection
PAYLOAD=$(echo "$INPUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)

# tool_input is an object - serialize it
tool_input = json.dumps(d.get("tool_input", {}))[:500]

# tool_response can be an object with stdout/stderr or a string
resp = d.get("tool_response", "")
if isinstance(resp, dict):
    tool_output = (resp.get("stdout", "") or resp.get("content", "") or "")[:300]
else:
    tool_output = str(resp)[:300]

out = {
    "event": "tool_use",
    "session_id": d.get("session_id", sys.argv[1]),
    "term_session_id": sys.argv[2],
    "tty_path": sys.argv[3],
    "working_dir": d.get("cwd", sys.argv[4]),
    "tool_name": d.get("tool_name", "unknown"),
    "tool_input": tool_input,
    "tool_output": tool_output,
    "transcript_path": d.get("transcript_path", "")
}
print(json.dumps(out))
' "$SESSION_ID" "$TERM_SID" "$TTY_PATH" "$PWD" 2>/dev/null)

post_event_payload "$PAYLOAD"

exit 0
