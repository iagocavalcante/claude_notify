import Config

config :claude_notify,
  port: 4040,
  telegram_base_url: "https://api.telegram.org",
  max_event_concurrency: 8,
  memory_capture_enabled: true,
  memory_briefing_injection: false,
  memory: %{
    max_observations_per_session: 500,
    max_observations_per_project: 5_000,
    max_ingest_keys: 50_000,
    max_title_bytes: 160,
    max_body_bytes: 2_000,
    max_metadata_entries: 20,
    max_collection_entries: 50,
    max_handoff_summary_bytes: 4_000,
    max_handoff_item_bytes: 500,
    max_handoff_items: 20,
    max_context_bytes: 8_000,
    max_page_bytes: 12_000,
    max_search_results: 8,
    max_search_snippet_bytes: 700,
    max_briefing_bytes: 6_000,
    conversation_max_pending: 10,
    conversation_max_prompt_bytes: 8_000
  },
  claude_chrome_enabled: false,
  keep_awake_while_working: true,
  preview: %{
    default_provider: :auto,
    ttl_seconds: 7_200,
    port_start: 41_000,
    port_end: 41_999,
    cloudflare: %{
      api_token: nil,
      account_id: nil,
      zone_id: nil,
      domain: nil,
      allowed_emails: [],
      access_session_duration: "1h"
    },
    tailscale: %{
      mode: :serve,
      https_port_start: 44_300,
      https_port_end: 44_399,
      ssh_host: nil,
      remote_port_start: 45_300,
      remote_port_end: 45_399
    }
  },
  webhook_max_skew_seconds: 300,
  transcript_allowed_roots: [
    "/tmp",
    Path.join(System.user_home!(), ".claude"),
    Path.join(System.user_home!(), ".codex")
  ],
  terminal_history_max_entries: 60,
  terminal_history_max_entry_bytes: 6_000,
  # Git repositories below these directories are discovered automatically and
  # become selectable from Telegram. Override with
  # CLAUDE_NOTIFY_WORKSPACE_ROOTS (comma-separated absolute paths).
  workspace_roots: [Path.join(System.user_home!(), "Workspaces")],
  workspace_discovery_depth: 4,
  # Optional explicit project paths (ClaudeNotify.ProjectRegistry), useful for
  # aliases or repos outside workspace_roots. Each entry is validated at load
  # (path exists and is a git repo toplevel) and dropped with a warning log
  # otherwise. This list overrides auto-discovered names and is itself
  # overridden by ~/.claude_notify/projects.json on name collisions.
  #
  # projects: [
  #   %{name: "claude_notify", aliases: ["cn"], path: "/Users/me/code/claude_notify"},
  #   %{name: "trainer_gym_ai", aliases: ["tg"], path: "/Users/me/code/trainer-gym-ai"}
  # ]
  projects: []

import_config "#{config_env()}.exs"
