# Claude Notify

Elixir app that sends interactive Telegram notifications for Claude Code and Codex terminal sessions. Monitor what either agent is doing, respond to permission prompts, and send prompts — all from Telegram.

## Features

- **Quiet mode** — ~7 messages per session instead of 50+; no per-tool spam
- **Edit-in-place activity** — a single message is updated silently showing what the agent is currently doing (tool name, file paths)
- **Consolidated diffs** — `git diff` shown inline before permission prompts and at session end so you see exactly what changed
- **Reply-to-session** — reply to any message to send text to that session's terminal (no need to `/select` first)
- **Compact session lifecycle** — minimal start/end messages with project name and session ID
- **Interactive approvals** — respond to permission prompts with Yes / No / Yes (don't ask) / Esc directly from Telegram
- **Numbered option support** — for multi-choice prompts, choose options `1..9` from inline buttons
- **Safer terminal injection** — text input is sent via clipboard paste with TTY validation
- **Security hardening** — signed hook events (HMAC), replay protection, and Telegram chat authorization
- **Job dispatcher** — run a coding-agent CLI (`claude` or `codex`) headlessly against a discovered or registered project in its own isolated git worktree, with progress/completion reports and a `Create PR` button as the only push path
- **Watch mode** — opt in to a live, throttled transcript of a running job; off by default to keep the dispatcher quiet
- **Message-first tasks** — `/new`, tap a repository, then send ordinary messages instead of memorizing `/run` syntax
- **Durable project chats** — follow-up messages automatically resume the same Claude/Codex conversation and exact worktree; messages sent while busy queue as later turns and survive service restarts
- **One-command agent handoff** — `/agent` switches the next turn between Claude and Codex while preserving the workspace and delivering bounded project memory
- **Automatic project discovery** — Git repositories under your configured workspace roots appear in Telegram automatically
- **Unified dashboard** — one live view for Claude Code and Codex terminal sessions plus queued/running jobs
- **Idle session continuity** — completed Claude Code and Codex turns stay listed as idle, selectable sessions instead of disappearing
- **Accurate session lifecycle** — `SessionStart` lists new/resumed terminals immediately, `Stop` marks a turn idle, `SessionEnd` removes a closed terminal, and known sessions survive bot restarts
- **Sleep-safe development** — macOS idle sleep is prevented automatically while terminal sessions or dispatcher jobs are working, then released when all work becomes idle
- **Provider-agnostic web previews** — launch a job's web app through Cloudflare Access (email OTP) or Tailscale Serve (tailnet identity), then tear it down automatically
- **Reliable rich replies** — coding-agent Markdown renders cleanly in Telegram; long replies are delivered completely in balanced HTML chunks and visually attached to their prompt
- **Terminal-parity skills and Chrome** — Claude slash commands pass through Telegram, and isolated Claude jobs can use a paired Claude in Chrome extension
- **Durable cross-agent memory** — Claude and Codex exchange bounded project handoffs, while completed work remains searchable as app-owned Markdown

## How It Works

```
Claude Code or Codex (Terminal.app)
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
- **cloudflared** or **Tailscale CLI** (optional; choose either for remote web previews)
- **Google Chrome or Microsoft Edge plus the paired Claude browser extension** (optional; required only for browser-enabled Claude jobs)
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
- Register Claude Code hooks in `~/.claude/settings.json`
- Register Codex hooks in `~/.codex/hooks.json`
- Install a macOS LaunchAgent (auto-starts on login, auto-restarts on crash)
- Start the service and verify it's healthy

### 3. Grant Accessibility permissions

The app uses AppleScript to inject keystrokes into Terminal.app. macOS requires **Accessibility** permissions:

1. Go to **System Settings > Privacy & Security > Accessibility**
2. Add **Terminal.app** to the allowed list

Without this, responding to prompts from Telegram won't work.

### 4. Load hook signing env in your shell

Hook scripts sign events with `CLAUDE_NOTIFY_WEBHOOK_SECRET`. Before starting Claude Code or Codex in a shell session, load your `.env`:

```bash
set -a
source .env
set +a
```

### That's it

For Codex, open `/hooks` once and trust the newly registered Claude Notify hooks. Then open a Claude Code or Codex session in Terminal.app and you'll start getting Telegram notifications.

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

This table also drives Telegram's native "/" command menu, which self-registers automatically when the poller boots (`TelegramPoller.register_bot_commands/1`); a failed registration is logged and does not stop the bot.

| Command | Description |
|---------|-------------|
| `/new` | Choose a project and start a task with normal messages |
| `/agent [claude\|codex]` | Choose the agent for the current project chat |
| `/fresh` | Start a fresh conversation and worktree in the selected project |
| `/sessions` | List and select terminal sessions, including idle |
| `/approve` | Send Yes to the selected session |
| `/cancel` | Send Escape to the selected session (bare, no id) |
| `/dashboard` | Show Claude Code and Codex terminal sessions and jobs |
| `/run [claude\|codex] <project> <prompt>` | Launch a dispatcher job — see [Job dispatcher](#job-dispatcher) |
| `/jobs` | List known dispatcher jobs and their status |
| `/cancel <id>` | Cancel dispatcher job `<id>` |
| `/projects` | Choose from discovered and registered projects |
| `/memory <query\|recent\|brief\|status>` | Search or inspect the selected project's durable memory |
| `/watch <id>` | Watch dispatcher job `<id>`'s live transcript |
| `/unwatch <id>` | Stop watching dispatcher job `<id>` |
| `/preview <job-id> [cloudflare\|tailscale]` | Start a secure preview using the default or selected provider |
| `/previews` | List active web previews and remaining lifetime |
| `/unpreview <preview-id>` | Stop a preview and remove its provider route/resources |
| `/help` | Show available commands |

Reply to any terminal message to send text to that terminal session. If only one session is active, it is auto-selected. Standalone `yes`, `no`, `yes!`, `esc`, or a digit from `1` to `9` uses the same direct response keystroke as the matching permission button.

Registered bot commands in the table above are handled by Claude Notify. Every other slash command is forwarded verbatim to the selected destination, so project skills such as `/post-shorts make three variants` work like they do in Claude Code. A selected terminal session receives the text in its existing Terminal.app tab. A selected project behaves as a durable chat: the first message creates an isolated dispatcher workspace, later messages resume it, and follow-ups sent while the agent is busy run sequentially from a bounded durable queue.

## Security Model

- Only the configured `TELEGRAM_CHAT_ID` can control sessions from Telegram messages/callbacks.
- Hook requests to `POST /api/events` must include:
  - `X-Claude-Notify-Timestamp`
  - `X-Claude-Notify-Signature: sha256=<hmac>`
- Signatures are verified with `CLAUDE_NOTIFY_WEBHOOK_SECRET`.
- Replayed signed payloads are rejected.
- Preview creation is available only through the authorized Telegram chat. Cloudflare policies allow only configured OTP emails; Tailscale Serve obeys tailnet identity and grants. Tailscale Funnel is public and must be explicitly enabled.
- Tunnel tokens are passed to `cloudflared` through its environment, never placed in Telegram messages, process arguments, or the persistent preview store.
- The HTTP surface exposes exactly three routes — `GET /health`, asynchronous `POST /api/events`, and signed `POST /api/context` for bounded startup claims. Anything else, including `/debug/*`, returns `404`.

## Configuration

Core variables:

```bash
TELEGRAM_BOT_TOKEN=your_bot_token_here
TELEGRAM_CHAT_ID=your_chat_id_here
CLAUDE_NOTIFY_WEBHOOK_SECRET=replace_with_random_64_hex_chars
```

Optional variables:

```bash
MAX_EVENT_CONCURRENCY=8
WEBHOOK_MAX_SKEW_SECONDS=300
# Comma-separated directories whose Git repositories appear in /new
CLAUDE_NOTIFY_WORKSPACE_ROOTS="$HOME/Workspaces"
# Set false to disable automatic `caffeinate -i` while work is active
CLAUDE_NOTIFY_KEEP_AWAKE=true
# Add --chrome to Claude dispatcher/resume processes (requires a paired extension)
CLAUDE_NOTIFY_CLAUDE_CHROME=true

# Durable lifecycle observations (disable capture or tune bounded retention)
CLAUDE_NOTIFY_MEMORY_CAPTURE=true
# CLAUDE_NOTIFY_MEMORY_STORE_PATH="$HOME/.claude_notify/memory_store.dat"
# CLAUDE_NOTIFY_HANDOFF_STORE_PATH="$HOME/.claude_notify/handoffs.dat"
# CLAUDE_NOTIFY_CONVERSATION_STORE_PATH="$HOME/.claude_notify/conversations.dat"
# CLAUDE_NOTIFY_MEMORY_PAGES_ROOT="$HOME/.claude_notify/memory"
# CLAUDE_NOTIFY_MEMORY_BRIEFING_INJECTION=false
# CLAUDE_NOTIFY_MEMORY_MAX_PER_SESSION=500
# CLAUDE_NOTIFY_MEMORY_MAX_PER_PROJECT=5000
# CLAUDE_NOTIFY_MEMORY_MAX_INGEST_KEYS=50000
# CLAUDE_NOTIFY_MEMORY_MAX_TITLE_BYTES=160
# CLAUDE_NOTIFY_MEMORY_MAX_BODY_BYTES=2000
# CLAUDE_NOTIFY_MEMORY_MAX_METADATA_ENTRIES=20
# CLAUDE_NOTIFY_MEMORY_MAX_FILE_PATHS=50
# CLAUDE_NOTIFY_HANDOFF_MAX_SUMMARY_BYTES=4000
# CLAUDE_NOTIFY_HANDOFF_MAX_ITEM_BYTES=500
# CLAUDE_NOTIFY_HANDOFF_MAX_ITEMS=20
# CLAUDE_NOTIFY_MEMORY_MAX_CONTEXT_BYTES=8000
# CLAUDE_NOTIFY_MEMORY_MAX_PAGE_BYTES=12000
# CLAUDE_NOTIFY_MEMORY_MAX_SEARCH_RESULTS=8
# CLAUDE_NOTIFY_MEMORY_MAX_SNIPPET_BYTES=700
# CLAUDE_NOTIFY_MEMORY_MAX_BRIEFING_BYTES=6000
# CLAUDE_NOTIFY_CONVERSATION_MAX_PENDING=10
# CLAUDE_NOTIFY_CONVERSATION_MAX_PROMPT_BYTES=8000

# Optional previews: auto selects the first available secure provider
CLAUDE_NOTIFY_PREVIEW_PROVIDER=auto
CLAUDE_NOTIFY_PREVIEW_TTL_SECONDS=7200

# Cloudflare Access provider
CLOUDFLARE_API_TOKEN=your_scoped_api_token
CLOUDFLARE_ACCOUNT_ID=your_account_id
CLOUDFLARE_ZONE_ID=your_zone_id
# Use the zone apex so generated names stay one level deep:
# preview-12-a1b2c3.example.com
CLOUDFLARE_PREVIEW_DOMAIN=example.com
CLOUDFLARE_ACCESS_EMAILS="you@example.com,tester@example.com"
CLOUDFLARE_ACCESS_SESSION_DURATION=1h

# Tailscale provider (serve is private; funnel is public)
TAILSCALE_PREVIEW_MODE=serve
# TAILSCALE_PATH=/path/to/tailscale
# Optional: use Tailscale on an existing SSH relay instead of installing it locally
# TAILSCALE_SSH_HOST=ssh-tron
```

Dispatcher settings (job commands, watch mode) are `config.exs`/`runtime.exs` keys, not `.env` variables — see [Job dispatcher](#job-dispatcher) for the full list with defaults.

### Lifecycle observation capture

Terminal hooks and dispatcher jobs write a small, versioned observation stream to
`~/.claude_notify/memory_store.dat`. Observations share the canonical project ID
across repository roots, nested directories, and Git worktrees. The stream keeps
prompts, assistant text, lifecycle outcomes, canonical tool families, and safe
project-relative file paths. It intentionally never keeps shell arguments, tool
output, diffs, environment maps, or paths outside the project boundary.

Writes are atomic and mode `0600`, webhook/engine replays are idempotent, and
retention is bounded independently per session and project. Ingest keys outlive
evicted observation bodies so an older replay cannot immediately reinsert data.
An unknown or corrupt on-disk schema fails closed until the store is explicitly
cleared. File content capture remains disabled by default; project-local content
exclusions are deliberately staged until any later issue proposes enabling it.
At substantive stop/job boundaries, the observation stream deterministically
produces a typed portable handoff. A newer automatic checkpoint supersedes the
prior open one from the same source. Claims are atomic and retry-safe: the same
receiving session gets the same accepted handoff after a timeout or restart,
while later sessions cannot consume it. Native engine resume suppresses the
same engine-session handoff so context is not duplicated.

Completed substantive sessions and jobs also write readable episodic Markdown
under `~/.claude_notify/memory/projects/<project-id>/episodes/`. Markdown is the
source of truth; `memory-index.sqlite3` is a derived SQLite FTS5 index that can
be deleted and rebuilt. `/memory <query>`, `/memory recent`, `/memory brief`,
and `/memory status` always stay inside the selected canonical project.

Session-start hooks synchronously call the dedicated signed `/api/context`
route with a two-second hard timeout, then print any claimed handoff to agent
stdout. Dispatcher jobs receive the same context after their non-negotiable
worktree rules. Injected text is delimited and explicitly labeled untrusted
historical evidence; current instructions and the checkout remain authoritative.
Optional recurring briefing injection is disabled by default because it spends
tokens on every start (`CLAUDE_NOTIFY_MEMORY_BRIEFING_INJECTION=true` enables it).

Default field limits are 160 bytes for titles, 2,000 bytes for bodies, 20
metadata fields, and 50 file paths/list items. Project and session labels are
capped at 200 bytes; source event IDs at 240; metadata keys at 80; scalar values
at 1,000; and list values at 500 bytes each. The environment variables above
configure the continuity-facing title/body, metadata, and file-count bounds.

When `CLAUDE_NOTIFY_CLAUDE_CHROME=true`, every Claude dispatcher and resumed job starts with `--chrome`, including jobs inside isolated worktrees. Bot commands such as `/jobs` remain owned by Telegram; any other slash command, such as a project `/post-shorts` skill or Claude's `/chrome`, is sent verbatim to the selected session/project.

Load this env in the shell where you run Claude Code so hooks can sign webhook requests:

```bash
set -a
source .env
set +a
```

## Claude skills and Chrome from Telegram

Claude Notify preserves Claude Code's message-oriented workflow: select a destination, then send normal prompts or project slash commands from Telegram. Browser access depends on which kind of destination is selected:

| Selected destination | What happens | Chrome behavior |
|----------------------|--------------|-----------------|
| Terminal session from `/sessions` | The message or slash command is pasted into the existing Claude Code process | Uses that process's current browser connection. Send `/chrome` first if it was not started with Chrome enabled. |
| Project from `/new` or `/projects` | A new Claude or Codex job runs in an isolated worktree | Claude jobs start with `--chrome` when `CLAUDE_NOTIFY_CLAUDE_CHROME=true`; Codex jobs are unchanged. |
| Completed job activity message | A reply creates a fresh job that resumes the recorded agent conversation | Resumed Claude jobs also receive `--chrome` when enabled. |

To enable full Claude browser tools for new project jobs:

1. Install the [Claude browser extension](https://code.claude.com/docs/en/chrome) in Chrome or Edge, pair it with Claude Code, and leave the browser running.
2. Set `CLAUDE_NOTIFY_CLAUDE_CHROME=true` in this project's `.env`.
3. Restart Claude Notify so the runtime configuration is reloaded.
4. In Telegram, send `/new`, choose a project and Claude, then send a normal prompt or a skill such as `/post-shorts ...`.

The extension pairing belongs to the local Claude/browser installation, so it remains available when a dispatcher job runs from a generated worktree. The job can use the visible browser's existing login state and extension permissions. Login challenges, CAPTCHAs, confirmation dialogs, and sites outside the extension's allowed scope may still require manual interaction.

If Claude recognizes a skill but reports that browser tools are unavailable, check that the extension says it is connected, Chrome is running, and the job was created after enabling the environment variable and restarting the service. Existing terminal processes do not gain the `--chrome` startup flag retroactively; use `/chrome` in that session or start a new Claude Code process.

## Ephemeral web previews

After a dispatcher job creates a web app, tap **Preview** on its completion report or send `/preview <job-id> [cloudflare|tailscale]`. Claude Notify will:

1. Start the app inside that job's isolated worktree on an available loopback port.
2. Select the configured provider automatically, or use the provider named in the command.
3. Return the HTTPS URL in Telegram and keep the Mac awake while the preview is active.
4. Remove the local process and provider resources when its TTL expires or `/unpreview <preview-id>` is sent. Saved resources are reconciled after a service restart.

### Cloudflare Access

This is best for browser-only testers outside your private network. It creates a remotely managed Cloudflare Tunnel, a proxied random hostname such as `preview-12-a1b2c3.example.com`, and a self-hosted Access app restricted to `CLOUDFLARE_ACCESS_EMAILS` through email One-time PIN.

Install `cloudflared` on macOS with `brew install cloudflared`. The Cloudflare zone must already use Cloudflare nameservers and the account must have Zero Trust configured. Create a scoped API token with these permissions:

- `Cloudflare One Connector: cloudflared Write` (or the equivalent Tunnel Write permission)
- `DNS Write` for the preview zone
- `Access: Apps and Policies Write`
- `Access: Organizations, Identity Providers, and Groups Write`

OTP is discovered automatically; if the account does not yet have a One-time PIN identity provider, Claude Notify creates one. Only explicitly configured email addresses are placed in the allow policy—there is no “allow everyone” fallback.

### Tailscale

This has no Cloudflare account, domain, DNS, or API-token requirement. Install and connect the Tailscale CLI on the development machine, leave `TAILSCALE_PREVIEW_MODE=serve`, and set `CLAUDE_NOTIFY_PREVIEW_PROVIDER=tailscale` (or leave it on `auto` when Cloudflare is not configured). Each preview receives its own HTTPS port on the machine's `*.ts.net` hostname. Access stays inside the tailnet and follows its identity-aware grants.

If Tailscale runs on another machine you already access over SSH, set `TAILSCALE_SSH_HOST` to that SSH config alias. Claude Notify opens a loopback-only reverse forward for each preview and runs Tailscale Serve on the relay. The application and worktree remain on the development machine; only preview traffic crosses SSH. SSH must work non-interactively for the background service.

`TAILSCALE_PREVIEW_MODE=funnel` is an explicit public-internet mode. Funnel supplies HTTPS but no login or OTP wall, so anyone with the URL can access the preview. It is intended for public test endpoints and webhooks, not private application data. Funnel supports at most three concurrent routes here because Tailscale restricts it to ports `443`, `8443`, and `10000`.

The app command is auto-detected for common npm/pnpm/yarn/bun, Phoenix, and static HTML projects. For other projects, commit a `.claude-notify.json` file at the repository root. Commands are argv arrays, not shell strings, so pipes and shell expansion are intentionally unavailable:

```json
{
  "preview": {
    "command": [
      "npm",
      "run",
      "dev",
      "--",
      "--host",
      "${HOST}",
      "--port",
      "${PORT}"
    ]
  }
}
```

`${HOST}` resolves to `127.0.0.1`; `${PORT}` is allocated from `41000..41999`. The preview runner does not install dependencies, execute migrations, or run arbitrary Telegram-provided shell commands. Put project-specific preparation in the coding job or a safe project script.

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

### Codex hooks

Codex uses the same lifecycle scripts through `~/.codex/hooks.json`. The setup script merges these entries automatically: `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, `PostToolUse`, `Stop`, and `SessionEnd`. Each command is prefixed with `CLAUDE_NOTIFY_ENGINE=codex` so Telegram and the dashboard label the terminal correctly.

After adding or changing Codex hooks, run Codex interactively and open `/hooks` to review and trust them. Codex skips untrusted command hooks.

Codex lifecycle hooks are enabled by default. If your config explicitly sets `[features].hooks = false`, remove that override or set it to `true`.

</details>

## Job dispatcher

The dispatcher lets you hand a coding-agent CLI (`claude` or `codex`) a prompt against a discovered or explicitly registered project from Telegram, and let it run headless in its own isolated git worktree, without touching your own checkout. Every job command below requires the authorized `TELEGRAM_CHAT_ID` chat — see [Security Model](#security-model).

### Choosing workspace roots

By default the bot discovers Git repositories up to four directories deep under `~/Workspaces`. Each repository appears as a button in `/new` and `/projects`; no per-project setup is required. To use another location, set one or more comma-separated roots in `.env` and restart the bot:

```bash
CLAUDE_NOTIFY_WORKSPACE_ROOTS="$HOME/code,$HOME/clients"
```

Discovery stays within those roots, ignores common dependency/build directories, and does not follow symlinks outside a root. If two repositories share a basename, the picker uses their relative paths (for example, `acme/app` and `personal/app`).

### Registering explicit projects and aliases

Explicit entries remain useful for aliases or repositories outside the discovered workspace roots. Add them to `config/config.exs` (or your `config/runtime.exs`):

```elixir
config :claude_notify,
  projects: [
    %{name: "claude_notify", aliases: ["cn"], path: "/Users/me/code/claude_notify"},
    %{name: "trainer_gym_ai", aliases: ["tg"], path: "/Users/me/code/trainer-gym-ai"}
  ]
```

Each entry needs an absolute `path` that is the toplevel of a git repository; invalid entries are dropped with a warning log rather than failing the whole registry. `aliases` is optional. Entries can also live in `~/.claude_notify/projects.json` for machine-local projects that shouldn't be committed:

```json
[
  {"name": "claude_notify", "aliases": ["cn"], "path": "/Users/me/code/claude_notify"},
  {"name": "trainer_gym_ai", "aliases": ["tg"], "path": "/Users/me/code/trainer-gym-ai"}
]
```

File entries take precedence over application-config entries with the same name. The registry is (re)loaded on every job-launch attempt, so editing either source is picked up without restarting the app.

### Commands

**`/new`** — opens a paginated project picker and establishes a fresh durable project chat. Tap a repository, optionally switch between Claude and Codex, then send your task as a normal Telegram message. Later ordinary messages automatically continue the latest native agent session in the exact same worktree. A message sent while a turn is running is durably queued and starts after that turn completes. The selected project, agent, conversation head, and pending turns survive app restarts. Use `/sessions` to switch temporarily to an already-open terminal session.

**`/agent [claude|codex]`** — changes the agent for the next turn without changing the current worktree. A same-agent turn uses native Claude/Codex resume. A cross-agent turn starts the other engine in that workspace and consumes the bounded durable handoff produced by the previous turn. With no argument, `/agent` shows one-tap agent buttons.

**`/fresh`** — clears the active conversation chain and pending turns while retaining the selected project and agent. The next message receives a new isolated worktree. `/new` is the broader reset when the project should change too.

**`/run [claude|codex] <project> <prompt>`** — launches a job. `<project>` is a discovered name, explicit name, or alias; the rest of the message after it is the prompt verbatim. The engine defaults to `claude` when omitted.

The engine token, when present, **always wins over the project name** — if the first word after `/run` is exactly `claude` or `codex`, it's consumed as the engine selector, not the project name, even if you have a project registered under that exact name:

```
/run trainer fix the flaky test          → engine claude, project "trainer"
/run codex trainer fix the flaky test    → engine codex,  project "trainer"
/run claude claude fix the flaky test    → engine claude, project "claude" (project named "claude" — must repeat the engine token to reach it)
```

An unregistered project name replies with the list of known projects instead of failing silently. A missing prompt (or missing project) replies with a usage message; no job is created.

**`/jobs`** — lists every known job with its id, engine, project, and status (`##{id} #{engine} #{project} - #{status}`).

**`/cancel <id>`** — cancels dispatcher job `<id>` (must parse as a bare integer): transitions it to `:discarded` and stops its running engine process, if any. **`/cancel`** with no argument (or a non-numeric one) is unrelated — it's the pre-existing shortcut that sends Escape to the currently selected terminal session.

**`/projects`** — opens the same paginated working-directory picker as `/new`.

**`/memory <query>`** — runs bounded lexical search inside the selected session
or project's canonical memory. `recent` lists episodic pages, `brief` renders a
deterministic project briefing, and `status` reports Markdown/index health. The
command also works when replying to a tracked terminal or dispatcher message.

**`/watch <id>` / `/unwatch <id>`** — see [Watch mode](#watch-mode) below; equivalent to tapping the `[Watch]`/`[Unwatch]` button on the job's activity message.

**Reply to a job's activity message to make it the active chat and continue it.** Each turn remains a separate immutable job record for auditability, but the new turn reuses the original app-owned worktree and branch after validating them against `git worktree list`. Same-agent turns pass the recorded native session id to Claude/Codex. If that session id or worktree is unavailable, the turn falls back safely to a fresh engine invocation with portable project memory. Replies to a busy chat are queued instead of rejected.

### Report buttons and the human gate

When a job finishes, its activity message is replaced with a report and buttons:

- **Completed** → `[Show diff]` `[Create PR]` `[Discard]`. `Show diff` sends the job's `git diff` against the repo's current branch as a separate message (or "No changes to show." if empty). **`Create PR` is the only path in this codebase that ever runs `git push` or `gh pr create`** — it pushes the job's branch (`git push -u origin <branch>`) and then runs `gh pr create`, replying with the PR URL on success or an explicit failure message (distinguishing a push failure from a push-succeeded-but-`gh`-failed case) otherwise. It refuses if the job isn't `:completed` or if its worktree no longer exists on disk.
- **Failed** → `[Show output]` `[Discard]`. `Show output` sends the job's `error_tail` (the engine's own reported error, or the tail of its raw stdout if it crashed before reporting one).
- **`Discard`** tears down the job's worktree and branch (`ClaudeNotify.WorktreeManager.discard/1`) and edits the report to say so. For a job still `:queued`/`:running`/`:awaiting_input` (reachable via `/cancel <id>` too), this also drives the status to `:discarded`. For an already-terminal job (`:completed`/`:failed`), discarding only removes the worktree — the job's historical `:completed`/`:failed` status is left untouched, since the job did genuinely finish; only its now-unwanted worktree is being cleaned up.

No other code path pushes or opens a pull request. The wrapped prompt every job runs under also explicitly instructs the engine itself never to push or open a PR, and to stay inside its own worktree.

### Watch mode

Off by default (quiet mode) — a job's activity message only ever shows an aggregate action/file counter, not per-tool output. Opting in:

- Tap **`[Watch]`** on a job's activity message, or send **`/watch <id>`**. For a still-running job this sends one new message with the current transcript snapshot and swaps the activity message's button to `[Unwatch]`; that transcript message is then edited in place as new entries arrive.
- Edits are throttled to at most one per `:claude_notify, :watch_edit_interval_ms` (default 2000ms) — a burst of tool calls within the window coalesces into a single trailing edit, not one Telegram edit per tool call.
- The transcript is bounded to Telegram's 4096-character message limit; when it doesn't fit, the **oldest** entries are dropped first so the most recent activity stays visible, with a truncation notice at the top.
- **`[Unwatch]`** (or `/unwatch <id>`) finalizes the transcript message with a fresh read and flips the button back to `[Watch]`.
- **Watching an already-terminal job almost always replies "transcript gone."** A job's transcript is held in memory only while it runs and is discarded immediately after its completion notifier fires — by the time you tap `[Watch]` on a job that already finished, the transcript is very likely already gone. Watching a job *while it's still running*, or being watched at the moment it completes, is the only way to see its transcript; the completion report itself (diff/output buttons) is unaffected either way.
- Watching an unknown job id, or a job you're already watching, replies with a clear error rather than silently doing nothing.

### Engine support

| Engine | Status |
|--------|--------|
| `claude` | Drives the `claude` CLI (`claude [--chrome] -p ... --output-format stream-json --verbose --dangerously-skip-permissions`) via `ClaudeNotify.Engine.Claude`. `--chrome` is added when `CLAUDE_NOTIFY_CLAUDE_CHROME=true`, including for resumed jobs. Its `stream-json` event parsing and browser-tool connection were confirmed against real invocations. |
| `codex` | Drives the `codex` CLI (`codex exec --experimental-json --sandbox workspace-write --ask-for-approval never ...`) via `ClaudeNotify.Engine.Codex`. Fully implemented and unit-tested, but its event-shape parsing was verified only from the `@openai/codex-sdk` source and offline CLI flag-parsing probes, not a live run — see `ClaudeNotify.Engine.Codex`'s moduledoc for exactly what is and isn't confirmed. `--experimental-json` is an undocumented, explicitly "experimental" upstream flag; a future `codex-cli` release could change or remove it. |

### Concurrency

Up to `:claude_notify, :job_concurrency` (default 3) jobs run at once; requests beyond the cap queue FIFO and launch as slots free up (`ClaudeNotify.JobSupervisor.Dispatcher`).

### Safety model

- **Worktree isolation** — every job gets its own `git worktree` on a fresh branch (`job/<job_id>-<slug>`) under a dedicated base directory (`~/.claude_notify/worktrees/<repo>/<job_id>` by default, configurable via `:claude_notify, :worktree_base_dir`). The job's prompt is wrapped with rules telling the engine to stay inside that worktree and never touch any other checkout.
- **Allowlisted paths only** — a job can only target a validated Git repository discovered inside a configured workspace root or explicitly listed in the registry. Unknown names fail cleanly instead of falling back to arbitrary paths.
- **Authorized chat gate** — every dispatcher command and button callback is rejected unless it comes from the configured `TELEGRAM_CHAT_ID`, same as every other Telegram command in this app.
- **Human gate: nothing pushes or opens a PR except `Create PR`** — the wrapped prompt explicitly forbids the engine itself from running `git push` or opening a pull request; committing locally is the end of a job's own work. Turning a job's commit into a PR is the deliberate, separate, human-triggered `Create PR` button described above — no other code path does this.
- **Boot reconciliation** — see below.

### Reconciliation

`ClaudeNotify.JobReconciler` runs once at application boot (right after `JobStore`/`JobSupervisor` come up) to reconcile job state against reality after a restart:

- Any job still marked `:running` at boot has, by construction, no surviving process — `JobRunner`s are never restarted (`restart: :temporary`) and the job record tracks no OS PID, so `:running` at boot always means dead. Each such job is transitioned to `:failed`, and any Telegram message(s) tracked for it are edited to say it was interrupted (jobs with no tracked message are just marked failed — no edit is attempted).
- Worktrees found on disk with no matching `JobStore` record are **listed and reported** to the authorized Telegram chat with a cleanup prompt. They are **never auto-deleted** — cleanup is a human decision.
- Worktrees belonging to `:completed`/`:discarded` jobs older than `:claude_notify, :job_worktree_retention_seconds` (default 7 days, judged against the job's `updated_at`) are swept automatically.

Reconciliation never crashes the app — any failure during the pass is caught and logged, and boot proceeds regardless. It's disabled under `MIX_ENV=test` (`start_job_reconciler: false` in `config/test.exs`) so the test suite never reconciles against a developer's real `~/.claude_notify` state.

### Dispatcher configuration reference

These are the main dispatcher keys under `config :claude_notify, ...`. Environment-backed keys show their corresponding variable below.

| Key | Default | Purpose |
|-----|---------|---------|
| `:workspace_roots` | `[~/Workspaces]` | Roots scanned for selectable Git repositories; set with `CLAUDE_NOTIFY_WORKSPACE_ROOTS` |
| `:workspace_discovery_depth` | `4` | Maximum directory depth scanned below each workspace root |
| `:projects` | `[]` | Optional explicit project entries and aliases — see [Registering explicit projects and aliases](#registering-explicit-projects-and-aliases) |
| `:claude_chrome_enabled` | `false` | Add `--chrome` to new and resumed Claude dispatcher jobs; set with `CLAUDE_NOTIFY_CLAUDE_CHROME` |
| `:job_concurrency` | `3` | Max jobs running at once before new launches queue FIFO |
| `:job_worktree_retention_seconds` | `604_800` (7 days) | How long a `:completed`/`:discarded` job's worktree survives before boot reconciliation sweeps it |
| `:start_job_reconciler` | `true` (`false` in `config/test.exs`) | Whether `ClaudeNotify.JobReconciler` runs its one-shot pass at boot |
| `:job_transcript_max_entries` | `200` | Max transcript entries kept per job (oldest dropped first) |
| `:job_transcript_max_diff_bytes` | `4_000` | Max size of a single captured per-file diff in a transcript entry, before truncation |
| `:watch_edit_interval_ms` | `2_000` | Minimum time between throttled watch-message edits |
| `:worktree_base_dir` | `~/.claude_notify/worktrees` | Base directory job worktrees are created under |
| `:job_store_path` | `~/.claude_notify/job_store.dat` | Where `ClaudeNotify.JobStore` persists job records to disk |
| `:conversation_store_path` | `~/.claude_notify/conversations.dat` | Durable selected project/agent, job head, and pending chat turns; set with `CLAUDE_NOTIFY_CONVERSATION_STORE_PATH` |
| `:memory.conversation_max_pending` | `10` | Maximum durable follow-up turns per chat; set with `CLAUDE_NOTIFY_CONVERSATION_MAX_PENDING` |
| `:memory.conversation_max_prompt_bytes` | `8_000` | Maximum UTF-8 bytes retained for one queued turn; set with `CLAUDE_NOTIFY_CONVERSATION_MAX_PROMPT_BYTES` |

### Dispatcher architecture

```
ProjectRegistry   — discovers workspace repos and resolves names/aliases to validated paths
      |
WorktreeManager   — creates/discards the job's isolated git worktree + branch inside that repo
      |
JobStore          — persists job records (status, worktree/branch, engine_session_id) to disk
      |
ConversationStore — persists each Telegram project's active agent, job chain, and queued turns
      |
JobSupervisor /   — enforces the concurrency cap + FIFO queue, then supervises one
  Dispatcher        JobRunner process per running job
      |
JobRunner         — drives the engine CLI as a Port, parses its output, records the
                     transcript, and pushes progress/completion back to JobStore
      |
Engine.Claude /   — engine-specific command building + event parsing; Claude can connect
  Engine.Codex      to the paired browser extension when --chrome is enabled
      |
TelegramPoller    — the only caller of the above: guides /new and parses /agent /fresh /run /jobs
                     /cancel /projects /memory /watch /unwatch and ordinary chat turns, renders activity/report
                     messages and buttons, and is the sole path that can push or open a PR
```

`JobTranscript` sits alongside `JobRunner`/`TelegramPoller` rather than in this vertical chain — it's a shared, in-memory ring buffer that `JobRunner` writes to as a job runs and `TelegramPoller` reads from for watch mode, discarded once the job's completion notifier has fired.

## Architecture

This covers the hook → Telegram → terminal-injection pipeline. For the job dispatcher's own modules (`ProjectRegistry`, `WorktreeManager`, `JobStore`, `JobSupervisor`, `JobRunner`, `Engine.*`, `JobTranscript`), see [Dispatcher architecture](#dispatcher-architecture) above.

| Module | Role |
|--------|------|
| `Router` | Plug HTTP server — receives hook events on `POST /api/events` and signed startup claims on `POST /api/context` |
| `EventAuth` | Verifies webhook timestamp + HMAC signature and replay protection |
| `EventHandler` | Routes events to session store and Telegram |
| `SessionStore` | GenServer tracking active sessions (ID, working dir, TTY path, transcript path) |
| `Telegram` | Telegram Bot API client (send messages, inline keyboards, long polling) |
| `TelegramPoller` | GenServer polling `getUpdates`, validating `chat_id`, and handling buttons/text commands |
| `ConversationStore` | Persists project-chat selection, active job/worktree chain, and bounded queued turns |
| `TerminalInjector` | AppleScript injection into Terminal.app by TTY path (clipboard paste for text input) |
| `MessageFormatter` | MarkdownV2 formatted messages with emoji tool icons |
| `TranscriptReader` | Reads Claude Code JSONL transcripts for last assistant response; Codex supplies its response in the Stop event |
| `PathSafety` | Sanitizes externally provided paths (e.g., transcript paths) |
| `HandoffStore` / `StartupContext` | Persist typed checkpoints and claim/render bounded untrusted context |
| `MemoryPages` | Writes project Markdown pages and owns the rebuildable SQLite FTS5 index |
| `Continuity` | Deterministically derives handoffs/pages from normalized observations |

## Hooks

| Hook | Event | What it sends |
|------|-------|---------------|
| `claude-notify-prompt.sh` | `UserPromptSubmit` | Session ID, prompt text, working dir, TTY path |
| `claude-notify-stop.sh` | `Stop` | Session ID, stop reason, working dir |
| `claude-notify-notify.sh` | Claude `Notification` / Codex `PermissionRequest` | Session ID, permission message, TTY path |
| `claude-notify-tool.sh` | `PostToolUse` | Session ID, tool name, input, output |

The same scripts support both agents and tag every event as `claude` or `codex`. All hooks send signed requests with:

- `X-Claude-Notify-Timestamp`
- `X-Claude-Notify-Signature: sha256=<hmac>`

Event signatures cover `<timestamp>.<raw-body>`. The startup claim route uses
the separate domain `<timestamp>./api/context.<raw-body>`, preventing a signed
lifecycle event from being replayed against the context endpoint.
