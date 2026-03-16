# Claude Notify

Elixir app that sends interactive Telegram notifications for Claude Code sessions. Monitor what Claude Code is doing, respond to permission prompts, and send prompts — all from Telegram.

## Features

- **Quiet mode** — ~7 messages per session instead of 50+; no per-tool spam
- **Edit-in-place activity** — a single message is updated silently showing what Claude is currently doing (tool name, file paths)
- **Consolidated diffs** — `git diff` shown inline before permission prompts and at session end so you see exactly what changed
- **Reply-to-session** — reply to any message to send text to that session's terminal (no need to `/select` first)
- **Compact session lifecycle** — minimal start/end messages with project name and session ID
- **Interactive approvals** — respond to permission prompts with Yes / No / Yes (don't ask) / Esc directly from Telegram
- **Numbered option support** — for multi-choice prompts, choose options `1..9` from inline buttons
- **Safer terminal injection** — text input is sent via clipboard paste with TTY validation
- **Security hardening** — signed hook events (HMAC), replay protection, Telegram chat authorization, and debug endpoint protection

## How It Works

```
Claude Code (Terminal.app)
    | hooks (signed curl POST + timestamp + HMAC)
    v
Elixir App (port 4040)
    | verify signature + replay window
    | update session state + format messages
    | sendMessage + inline_keyboard
    v
Telegram Bot
    | user taps button / types command
    v
Elixir App (long polling getUpdates)
    | validate configured chat_id
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
- Generate or prompt for a webhook signing secret (`CLAUDE_NOTIFY_WEBHOOK_SECRET`)
- Install Elixir dependencies
- Register all Claude Code hooks in `~/.claude/settings.json`
- Install a macOS LaunchAgent (auto-starts on login, auto-restarts on crash)
- Start the service and verify it's healthy

### 3. Grant Accessibility permissions

The app uses AppleScript to inject keystrokes into Terminal.app. macOS requires **Accessibility** permissions:

1. Go to **System Settings > Privacy & Security > Accessibility**
2. Add **Terminal.app** to the allowed list

Without this, responding to prompts from Telegram won't work.

### 4. Load hook signing env in your shell

Hook scripts sign events with `CLAUDE_NOTIFY_WEBHOOK_SECRET`. Before starting Claude Code in a shell session, load your `.env`:

```bash
set -a
source .env
set +a
```

### That's it

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
| `/sessions` | List and select active sessions |
| `/approve` | Send Yes to the selected session |
| `/cancel` | Send Escape to the selected session |
| `/dashboard` | Show live session dashboard |
| `/help` | Show available commands |

Reply to any message to send text to that session. If only one session is active, it is auto-selected.

## Security Model

- Only the configured `TELEGRAM_CHAT_ID` can control sessions from Telegram messages/callbacks.
- Hook requests to `POST /api/events` must include:
  - `X-Claude-Notify-Timestamp`
  - `X-Claude-Notify-Signature: sha256=<hmac>`
- Signatures are verified with `CLAUDE_NOTIFY_WEBHOOK_SECRET`.
- Replayed signed payloads are rejected.
- `GET /debug/sessions` is disabled by default and returns `403` unless explicitly enabled.

## Configuration

Core variables:

```bash
TELEGRAM_BOT_TOKEN=your_bot_token_here
TELEGRAM_CHAT_ID=your_chat_id_here
CLAUDE_NOTIFY_WEBHOOK_SECRET=replace_with_random_64_hex_chars
```

Optional variables:

```bash
ENABLE_DEBUG_ENDPOINTS=false
MAX_EVENT_CONCURRENCY=8
WEBHOOK_MAX_SKEW_SECONDS=300
```

Load this env in the shell where you run Claude Code so hooks can sign webhook requests:

```bash
set -a
source .env
set +a
```

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
CLAUDE_NOTIFY_WEBHOOK_SECRET=replace_with_random_64_hex_chars
# optional
ENABLE_DEBUG_ENDPOINTS=false
MAX_EVENT_CONCURRENCY=8
WEBHOOK_MAX_SKEW_SECONDS=300
```

Load env in the shell where Claude Code runs:

```bash
set -a
source .env
set +a
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
| `EventAuth` | Verifies webhook timestamp + HMAC signature and replay protection |
| `EventHandler` | Routes events to session store and Telegram |
| `SessionStore` | GenServer tracking active sessions (ID, working dir, TTY path, transcript path) |
| `Telegram` | Telegram Bot API client (send messages, inline keyboards, long polling) |
| `TelegramPoller` | GenServer polling `getUpdates`, validating `chat_id`, and handling buttons/text commands |
| `TerminalInjector` | AppleScript injection into Terminal.app by TTY path (clipboard paste for text input) |
| `MessageFormatter` | MarkdownV2 formatted messages with emoji tool icons |
| `TranscriptReader` | Reads Claude Code JSONL transcripts for last assistant response |
| `PathSafety` | Sanitizes externally provided paths (e.g., transcript paths) |

## Hooks

| Hook | Event | What it sends |
|------|-------|---------------|
| `claude-notify-prompt.sh` | `UserPromptSubmit` | Session ID, prompt text, working dir, TTY path |
| `claude-notify-stop.sh` | `Stop` | Session ID, stop reason, working dir |
| `claude-notify-notify.sh` | `Notification` | Session ID, notification message, TTY path |
| `claude-notify-tool.sh` | `PostToolUse` | Session ID, tool name, input, output |

All hooks send signed requests with:

- `X-Claude-Notify-Timestamp`
- `X-Claude-Notify-Signature: sha256=<hmac>`
