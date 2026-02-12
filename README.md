# Claude Notify

Elixir app that sends interactive Telegram notifications for Claude Code sessions. Monitor what Claude Code is doing, respond to permission prompts, and send prompts — all from Telegram.

## Features

- **Session tracking** — see when Claude Code sessions start, update, and stop
- **Tool use monitoring** — get formatted messages for each tool Claude uses (Read, Write, Bash, etc.)
- **Interactive buttons** — respond to permission prompts with Yes / No / Yes (don't ask) / Esc directly from Telegram
- **Remote prompting** — list active sessions, select one, and type prompts from Telegram
- **Last response** — see Claude's final response/summary in Telegram before permission prompts and on session end

## How It Works

```
Claude Code (Terminal.app)
    | hooks (curl POST)
    v
Elixir App (port 4040)
    | sendMessage + inline_keyboard
    v
Telegram Bot
    | user taps button / types command
    v
Elixir App (long polling getUpdates)
    | osascript (AppleScript)
    v
Terminal.app — keystrokes injected into correct tab
```

## Prerequisites

- **macOS** (uses AppleScript for terminal keystroke injection)
- **Terminal.app** (not iTerm2 — AppleScript targets Terminal.app tabs by TTY)
- **Elixir >= 1.19** and **Erlang/OTP >= 28**
- **python3** (used by hook scripts for JSON processing)
- A **Telegram Bot** (create one via [@BotFather](https://t.me/BotFather))

## Quick Setup

### 1. Create a Telegram Bot

1. Open Telegram and message [@BotFather](https://t.me/BotFather)
2. Send `/newbot` and follow the prompts
3. Copy the **bot token**
4. Send any message to your new bot, then get your **chat ID**:
   ```bash
   curl -s "https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates" | python3 -m json.tool
   ```
   Look for `"chat": {"id": 123456789}` — that number is your chat ID.

### 2. Run setup

```bash
git clone git@github.com:iagocavalcante/claude_notify.git
cd claude_notify
./setup.sh
```

The setup script will:
- Prompt for your Telegram bot token and chat ID (saved to `.env`)
- Install Elixir dependencies
- Register all Claude Code hooks in `~/.claude/settings.json`
- Install a macOS LaunchAgent (auto-starts on login, auto-restarts on crash)
- Start the service and verify it's healthy

### 3. Grant Accessibility permissions

The app uses AppleScript to inject keystrokes into Terminal.app. macOS requires **Accessibility** permissions:

1. Go to **System Settings > Privacy & Security > Accessibility**
2. Add **Terminal.app** to the allowed list

Without this, responding to prompts from Telegram won't work.

### That's it!

Open a Claude Code session in Terminal.app and you'll start getting Telegram notifications.

## Managing the Service

```bash
# Stop
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.claude-notify.plist

# Start
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude-notify.plist

# Restart
launchctl kickstart -k gui/$(id -u)/com.claude-notify

# View logs
tail -f ~/Library/Logs/claude-notify.log

# Run manually (foreground)
source .env && mix run --no-halt

# Run in IEx (foreground, interactive)
source .env && iex -S mix
```

## Telegram Commands

| Command | Description |
|---------|-------------|
| `/sessions` | List active Claude Code sessions with selection buttons |
| `/help` | Show available commands |

After selecting a session, any text you type in Telegram gets sent as input to that terminal session.

## Testing

```bash
mix test
```

## Manual Setup

If you prefer to configure things manually instead of using `setup.sh`:

<details>
<summary>Click to expand manual setup steps</summary>

### Environment variables

Create a `.env` file in the project root:

```bash
TELEGRAM_BOT_TOKEN=your_bot_token_here
TELEGRAM_CHAT_ID=your_chat_id_here
```

### Claude Code hooks

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/claude_notify/hooks/claude-notify-prompt.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/claude_notify/hooks/claude-notify-stop.sh"
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/claude_notify/hooks/claude-notify-notify.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/claude_notify/hooks/claude-notify-tool.sh"
          }
        ]
      }
    ]
  }
}
```

Replace `/path/to/claude_notify` with the actual absolute path to the project.

```bash
chmod +x hooks/*.sh
```

</details>

## Architecture

| Module | Role |
|--------|------|
| `Router` | Plug HTTP server — receives hook events on `POST /api/events` |
| `EventHandler` | Routes events to session store and Telegram |
| `SessionStore` | GenServer tracking active sessions (ID, working dir, TTY path) |
| `Telegram` | Telegram Bot API client (send messages, inline keyboards, long polling) |
| `TelegramPoller` | GenServer polling `getUpdates` for button presses and text commands |
| `TerminalInjector` | AppleScript keystroke injection into Terminal.app by TTY path |
| `MessageFormatter` | MarkdownV2 formatted messages with emoji tool icons |
| `TranscriptReader` | Reads Claude Code JSONL transcripts for last assistant response |

## Hooks

| Hook | Event | What it sends |
|------|-------|---------------|
| `claude-notify-prompt.sh` | `UserPromptSubmit` | Session ID, prompt text, working dir, TTY path |
| `claude-notify-stop.sh` | `Stop` | Session ID, stop reason, working dir |
| `claude-notify-notify.sh` | `Notification` | Session ID, notification message, TTY path |
| `claude-notify-tool.sh` | `PostToolUse` | Session ID, tool name, input, output |
