#!/usr/bin/env bash
# Claude Code / Codex SessionStart hook - registers a new or resumed idle session.

source "$(dirname "$0")/claude-notify-common.sh"

INPUT=$(cat)
TERM_SID="${TERM_SESSION_ID:-unknown}"
TTY_PATH="$(resolve_terminal_tty)"
[ "$TTY_PATH" = "unknown" ] && exit 0

PAYLOAD=$(echo "$INPUT" | python3 -c '
import json, sys, time, uuid
d = json.load(sys.stdin)
out = {
    "event": "session_start",
    "event_id": d.get("event_id") or d.get("hook_event_id") or str(uuid.uuid4()),
    "observed_at": int(time.time() * 1000),
    "engine": sys.argv[3],
    "session_id": d.get("session_id", "unknown"),
    "working_dir": d.get("cwd", "unknown"),
    "source": d.get("source", "startup"),
    "term_session_id": sys.argv[1],
    "tty_path": sys.argv[2]
}
print(json.dumps(out))
' "$TERM_SID" "$TTY_PATH" "${CLAUDE_NOTIFY_ENGINE:-claude}" 2>/dev/null)

post_event_payload "$PAYLOAD"

exit 0
