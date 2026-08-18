#!/usr/bin/env bash
# Claude Code / Codex SessionEnd hook - removes a genuinely closed terminal session.

source "$(dirname "$0")/claude-notify-common.sh"

INPUT=$(cat)

PAYLOAD=$(echo "$INPUT" | python3 -c '
import json, sys, time, uuid
d = json.load(sys.stdin)
out = {
    "event": "session_end",
    "event_id": d.get("event_id") or d.get("hook_event_id") or str(uuid.uuid4()),
    "observed_at": int(time.time() * 1000),
    "engine": sys.argv[1],
    "session_id": d.get("session_id", "unknown"),
    "reason": d.get("reason", "other")
}
print(json.dumps(out))
' "${CLAUDE_NOTIFY_ENGINE:-claude}" 2>/dev/null)

post_event_payload "$PAYLOAD"

exit 0
