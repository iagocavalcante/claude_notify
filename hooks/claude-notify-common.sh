#!/usr/bin/env bash

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HOOKS_DIR/../.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

post_event_payload() {
  local payload="$1"
  local secret="${CLAUDE_NOTIFY_WEBHOOK_SECRET:-}"
  local timestamp signature

  if [ -z "$payload" ] || [ -z "$secret" ]; then
    return 0
  fi

  timestamp="$(date +%s)"
  signature="$(python3 -c '
import hashlib, hmac, sys
secret = sys.argv[1].encode()
timestamp = sys.argv[2]
body = sys.argv[3]
message = f"{timestamp}.{body}".encode()
print(hmac.new(secret, message, hashlib.sha256).hexdigest())
' "$secret" "$timestamp" "$payload")"

  if [ -z "$signature" ]; then
    return 0
  fi

  curl -s -X POST http://localhost:4040/api/events \
    -H "Content-Type: application/json" \
    -H "X-Claude-Notify-Timestamp: $timestamp" \
    -H "X-Claude-Notify-Signature: sha256=$signature" \
    -d "$payload" \
    --connect-timeout 2 \
    --max-time 3 \
    > /dev/null 2>&1
}
