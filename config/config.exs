import Config

config :claude_notify,
  port: 4040,
  telegram_base_url: "https://api.telegram.org",
  max_event_concurrency: 8,
  webhook_max_skew_seconds: 300,
  transcript_allowed_roots: ["/tmp", Path.join(System.user_home!(), ".claude")],
  # Registered project paths (ClaudeNotify.ProjectRegistry). Jobs may only run
  # in a repo listed here - each entry is validated at load (path exists, is
  # a git repo toplevel) and dropped with a warning log otherwise. `aliases`
  # is optional. This list is merged with, and overridden on name collision
  # by, the optional user file at ~/.claude_notify/projects.json (same shape,
  # but with string keys since it's JSON), so machine-local projects don't
  # need to live in version control.
  #
  # projects: [
  #   %{name: "claude_notify", aliases: ["cn"], path: "/Users/me/code/claude_notify"},
  #   %{name: "trainer_gym_ai", aliases: ["tg"], path: "/Users/me/code/trainer-gym-ai"}
  # ]
  projects: []

import_config "#{config_env()}.exs"
