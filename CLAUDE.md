# Claude Notify

Elixir app that receives Claude Code hook events and sends Telegram notifications.

## Stack
- Plug + Bandit HTTP server on port 4040
- GenServer session store (in-memory)
- Req for Telegram Bot API
- Dotenvy for environment config

## Running
```bash
source .env && mix run --no-halt
```

## Testing
```bash
mix test
```

## Key modules
- `ClaudeNotify.Router` - HTTP endpoints (POST /api/events, GET /health)
- `ClaudeNotify.SessionStore` - GenServer tracking active sessions (stores tty_path for terminal injection)
- `ClaudeNotify.EventHandler` - Orchestrates events -> store -> telegram
- `ClaudeNotify.Telegram` - Sends messages via Telegram Bot API (supports inline keyboard buttons)
- `ClaudeNotify.MessageFormatter` - MarkdownV2 formatted messages
- `ClaudeNotify.TelegramPoller` - GenServer long-polling getUpdates for inline keyboard callbacks
- `ClaudeNotify.TerminalInjector` - AppleScript keystroke injection into Terminal.app by TTY path

## Interactive responses
Notification events (permission prompts) are sent to Telegram with inline keyboard buttons (Yes / Yes don't ask / No / Esc).
When a button is tapped, TelegramPoller receives the callback, looks up the session's TTY, and TerminalInjector sends the keystroke to the correct Terminal.app tab via osascript.
