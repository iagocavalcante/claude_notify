#!/usr/bin/env bash
# Claude Code SessionEnd hook - removes a genuinely closed terminal session.

source "$(dirname "$0")/claude-notify-common.sh"

INPUT=$(cat)

PAYLOAD=$(echo "$INPUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
out = {
    "event": "session_end",
    "session_id": d.get("session_id", "unknown"),
    "reason": d.get("reason", "other")
}
print(json.dumps(out))
' 2>/dev/null)

post_event_payload "$PAYLOAD"

exit 0
