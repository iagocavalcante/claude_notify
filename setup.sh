#!/usr/bin/env bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="com.claude-notify.plist"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME"
LOG_DIR="$HOME/Library/Logs"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo "=== Claude Notify Setup ==="
echo ""

# --- 1. Check prerequisites ---
if ! command -v mix &>/dev/null; then
  echo "ERROR: Elixir/mix not found. Install Elixir first."
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 not found. Install Python 3 first."
  exit 1
fi

# --- 2. Telegram bot config ---
# Check permissions on existing .env
if [ -f "$PROJECT_DIR/.env" ]; then
  perms=$(stat -f '%Lp' "$PROJECT_DIR/.env" 2>/dev/null || stat -c '%a' "$PROJECT_DIR/.env" 2>/dev/null)
  if [ "$perms" != "600" ]; then
    echo "WARNING: .env has insecure permissions ($perms). Fixing to 600..."
    chmod 600 "$PROJECT_DIR/.env"
  fi
fi

if [ -f "$PROJECT_DIR/.env" ]; then
  echo "Found existing .env file."
  source "$PROJECT_DIR/.env"
  echo "  TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:0:10}..."
  echo "  TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID"
  if [ -n "$CLAUDE_NOTIFY_WEBHOOK_SECRET" ]; then
    echo "  CLAUDE_NOTIFY_WEBHOOK_SECRET=${CLAUDE_NOTIFY_WEBHOOK_SECRET:0:10}..."
  else
    echo "  CLAUDE_NOTIFY_WEBHOOK_SECRET=<missing>"
  fi
  echo ""
  read -p "Keep existing config? (Y/n) " keep_env
  if [[ "$keep_env" =~ ^[Nn] ]]; then
    unset TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID CLAUDE_NOTIFY_WEBHOOK_SECRET
  fi
fi

if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ] || [ -z "$CLAUDE_NOTIFY_WEBHOOK_SECRET" ]; then
  echo ""
  echo "Create a Telegram bot via @BotFather and get your chat ID."
  echo "See README for instructions."
  echo ""
  if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
    read -p "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
  fi

  if [ -z "$TELEGRAM_CHAT_ID" ]; then
    read -p "Telegram Chat ID: " TELEGRAM_CHAT_ID
  fi

  if [ -z "$CLAUDE_NOTIFY_WEBHOOK_SECRET" ]; then
    read -p "Webhook secret (leave blank to auto-generate): " CLAUDE_NOTIFY_WEBHOOK_SECRET
  fi

  if [ -z "$CLAUDE_NOTIFY_WEBHOOK_SECRET" ]; then
    CLAUDE_NOTIFY_WEBHOOK_SECRET="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"
    echo "Generated webhook secret."
  fi

  (
    umask 077
    cat > "$PROJECT_DIR/.env" <<ENVEOF
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
CLAUDE_NOTIFY_WEBHOOK_SECRET=$CLAUDE_NOTIFY_WEBHOOK_SECRET
ENVEOF
  )
  chmod 600 "$PROJECT_DIR/.env"
  echo "Saved .env (permissions: owner-only)"
fi

# --- 3. Install dependencies ---
echo ""
echo "Installing dependencies..."
cd "$PROJECT_DIR"
mix deps.get --quiet

# --- 4. Make hooks executable ---
chmod +x "$PROJECT_DIR/hooks/"*.sh

# --- 5. Register Claude Code hooks ---
echo ""
echo "Configuring Claude Code hooks..."

mkdir -p "$HOME/.claude"

# Build the hooks JSON for this project
HOOKS_JSON=$(python3 -c "
import json, sys, os

settings_file = '$SETTINGS_FILE'
project_dir = '$PROJECT_DIR'

# Load existing settings or start fresh
if os.path.exists(settings_file):
    with open(settings_file) as f:
        settings = json.load(f)
else:
    settings = {}

hooks = settings.get('hooks', {})

hook_map = {
    'UserPromptSubmit': 'claude-notify-prompt.sh',
    'Stop': 'claude-notify-stop.sh',
    'Notification': 'claude-notify-notify.sh',
    'PostToolUse': 'claude-notify-tool.sh',
}

for event, script in hook_map.items():
    cmd = f'{project_dir}/hooks/{script}'
    entry = {'matcher': '', 'hooks': [{'type': 'command', 'command': cmd}]}

    if event not in hooks:
        hooks[event] = [entry]
    else:
        # Check if our hook is already registered
        already = any(
            cmd in h.get('command', '')
            for group in hooks[event]
            for h in group.get('hooks', [])
        )
        if not already:
            hooks[event].append(entry)

settings['hooks'] = hooks

with open(settings_file, 'w') as f:
    json.dump(settings, f, indent=2)

print('OK')
")

if [ "$HOOKS_JSON" = "OK" ]; then
  echo "Claude Code hooks registered in $SETTINGS_FILE"
else
  echo "WARNING: Could not configure hooks automatically."
  echo "See README for manual setup."
fi

# --- 6. Create run.sh ---
# Detect Erlang/Elixir paths
ELIXIR_BIN="$(dirname "$(which elixir)")"
ERLANG_BIN="$(dirname "$(which erl)")"

cat > "$PROJECT_DIR/run.sh" <<RUNEOF
#!/usr/bin/env bash
set -e
PROJECT_DIR="$PROJECT_DIR"
cd "\$PROJECT_DIR"
export PATH="$ERLANG_BIN:$ELIXIR_BIN:\$PATH"
set -a
source "\$PROJECT_DIR/.env"
set +a
exec mix run --no-halt
RUNEOF
chmod +x "$PROJECT_DIR/run.sh"

# --- 7. Install LaunchAgent ---
echo ""
echo "Installing LaunchAgent (auto-start on login)..."

cat > "$PLIST_PATH" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude-notify</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$PROJECT_DIR/run.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$PROJECT_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/claude-notify.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/claude-notify.error.log</string>
    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
PLISTEOF

# Load the service
launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"

echo "Service installed and started."

# --- 8. Verify ---
echo ""
echo "Waiting for app to start..."
sleep 4

if curl -s http://localhost:4040/health | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'Health: {d[\"status\"]}')" 2>/dev/null; then
  echo ""
  echo "=== Setup complete! ==="
  echo ""
  echo "  App running on port 4040"
  echo "  Logs: tail -f ~/Library/Logs/claude-notify.log"
  echo ""
  echo "  Manage service:"
  echo "    Stop:    launchctl bootout gui/\$(id -u) $PLIST_PATH"
  echo "    Start:   launchctl bootstrap gui/\$(id -u) $PLIST_PATH"
  echo "    Restart: launchctl kickstart -k gui/\$(id -u)/com.claude-notify"
  echo ""
  echo "  Don't forget to enable Accessibility for Terminal.app:"
  echo "    System Settings > Privacy & Security > Accessibility"
else
  echo ""
  echo "WARNING: App didn't respond on port 4040."
  echo "Check logs: tail -f ~/Library/Logs/claude-notify.error.log"
fi
