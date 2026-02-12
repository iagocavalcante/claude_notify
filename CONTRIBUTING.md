# Contributing to Claude Notify

Thanks for your interest in contributing! This project is open to contributions of all kinds: bug reports, feature requests, documentation improvements, and code.

## Getting Started

1. Fork the repository
2. Clone your fork and set up the project:
   ```bash
   git clone git@github.com:YOUR_USERNAME/claude_notify.git
   cd claude_notify
   mix deps.get
   ```
3. Copy the example env file and fill in your Telegram bot credentials:
   ```bash
   cp .env.example .env
   ```
4. Run the tests:
   ```bash
   mix test
   ```

## Development

Run the app locally:

```bash
source .env && iex -S mix
```

The app starts on port 4040. See the [README](README.md) for full setup instructions including Telegram bot creation and Claude Code hook registration.

## Making Changes

1. Create a feature branch from `main`:
   ```bash
   git checkout -b my-feature
   ```
2. Make your changes
3. Ensure tests pass:
   ```bash
   mix test
   ```
4. Format your code:
   ```bash
   mix format
   ```
5. Commit with a descriptive message:
   ```
   feat: add session filtering by project name
   fix: handle nil tty_path in terminal injector
   docs: clarify setup steps for Linux users
   ```
6. Push and open a Pull Request

## Commit Message Convention

Use [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` new features
- `fix:` bug fixes
- `docs:` documentation changes
- `refactor:` code restructuring
- `test:` test additions or changes
- `chore:` tooling, dependencies, CI

## Reporting Bugs

Open an issue with:

- Steps to reproduce
- Expected vs actual behavior
- Elixir/OTP version (`elixir --version`)
- Relevant log output (`tail ~/Library/Logs/claude-notify.log`)

## Feature Requests

Open an issue describing:

- The problem you're trying to solve
- Your proposed solution
- Any alternatives you've considered

## Architecture Overview

See the [README](README.md#architecture) for a module-by-module breakdown. Key things to know:

- **Hooks** are bash scripts that Claude Code runs on events (prompt, stop, tool use, notification). They POST JSON to the Elixir app.
- **EventHandler** routes events to the session store and Telegram.
- **TelegramPoller** handles incoming Telegram messages and button presses via long polling.
- **TerminalInjector** uses AppleScript to send keystrokes to Terminal.app tabs matched by TTY path.

## Code of Conduct

Be respectful and constructive. We're all here to build something useful.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
