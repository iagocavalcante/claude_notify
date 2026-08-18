#!/usr/bin/env bash
# Claude Code Notification / Codex PermissionRequest hook.

source "$(dirname "$0")/claude-notify-common.sh"

INPUT=$(cat)

SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
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

# Build payload using python3 - pass shell vars as argv to avoid injection
PAYLOAD=$(echo "$INPUT" | python3 -c '
import json, sys, time, uuid
d = json.load(sys.stdin)
message = d.get("message", "")
if not message and d.get("hook_event_name") == "PermissionRequest":
    tool_name = d.get("tool_name", "action")
    tool_input = d.get("tool_input") or {}
    detail = tool_input.get("description") if isinstance(tool_input, dict) else None
    if not detail and isinstance(tool_input, dict):
        detail = tool_input.get("command")
    if not detail:
        detail = json.dumps(tool_input, ensure_ascii=False)
    message = f"Allow {tool_name}?"
    if detail and detail != "{}":
        message += f"\n\n{detail}"
out = {
    "event": "notification",
    "event_id": d.get("event_id") or d.get("hook_event_id") or str(uuid.uuid4()),
    "observed_at": int(time.time() * 1000),
    "engine": sys.argv[6],
    "session_id": d.get("session_id", sys.argv[1]),
    "message": message,
    "term_session_id": sys.argv[2],
    "tty_path": sys.argv[3],
    "working_dir": d.get("cwd", sys.argv[4]),
    "transcript_path": d.get("transcript_path", ""),
    "git_diff": sys.argv[5]
}
print(json.dumps(out))
' "$SESSION_ID" "$TERM_SID" "$TTY_PATH" "$PWD" "$GIT_DIFF" "${CLAUDE_NOTIFY_ENGINE:-claude}" 2>/dev/null)

post_event_payload "$PAYLOAD"

exit 0
