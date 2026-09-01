import Config

if config_env() != :test do
  parse_int = fn
    nil, default ->
      default

    value, default ->
      case Integer.parse(value) do
        {parsed, ""} -> parsed
        _ -> default
      end
  end

  parse_bool = fn
    nil, default ->
      default

    value, default when is_binary(value) ->
      case String.downcase(String.trim(value)) do
        value when value in ["1", "true", "yes", "on"] -> true
        value when value in ["0", "false", "no", "off"] -> false
        _ -> default
      end
  end

  Dotenvy.source([".env", System.get_env()])

  workspace_roots =
    Dotenvy.env!(
      "CLAUDE_NOTIFY_WORKSPACE_ROOTS",
      :string,
      Path.join(System.user_home!(), "Workspaces")
    )
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> Path.expand()))

  preview_emails =
    System.get_env("CLOUDFLARE_ACCESS_EMAILS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  config :claude_notify,
    telegram_bot_token: Dotenvy.env!("TELEGRAM_BOT_TOKEN", :string),
    telegram_chat_id: Dotenvy.env!("TELEGRAM_CHAT_ID", :string),
    webhook_secret: Dotenvy.env!("CLAUDE_NOTIFY_WEBHOOK_SECRET", :string),
    workspace_roots: workspace_roots,
    claude_chrome_enabled: parse_bool.(System.get_env("CLAUDE_NOTIFY_CLAUDE_CHROME"), false),
    memory_capture_enabled: parse_bool.(System.get_env("CLAUDE_NOTIFY_MEMORY_CAPTURE"), true),
    memory_briefing_injection:
      parse_bool.(System.get_env("CLAUDE_NOTIFY_MEMORY_BRIEFING_INJECTION"), false),
    memory_store_path:
      System.get_env(
        "CLAUDE_NOTIFY_MEMORY_STORE_PATH",
        Path.join([System.user_home!(), ".claude_notify", "memory_store.dat"])
      )
      |> Path.expand(),
    handoff_store_path:
      System.get_env(
        "CLAUDE_NOTIFY_HANDOFF_STORE_PATH",
        Path.join([System.user_home!(), ".claude_notify", "handoffs.dat"])
      )
      |> Path.expand(),
    conversation_store_path:
      System.get_env(
        "CLAUDE_NOTIFY_CONVERSATION_STORE_PATH",
        Path.join([System.user_home!(), ".claude_notify", "conversations.dat"])
      )
      |> Path.expand(),
    memory_pages_root:
      System.get_env(
        "CLAUDE_NOTIFY_MEMORY_PAGES_ROOT",
        Path.join([System.user_home!(), ".claude_notify", "memory"])
      )
      |> Path.expand(),
    memory: %{
      max_observations_per_session:
        parse_int.(System.get_env("CLAUDE_NOTIFY_MEMORY_MAX_PER_SESSION"), 500),
      max_observations_per_project:
        parse_int.(System.get_env("CLAUDE_NOTIFY_MEMORY_MAX_PER_PROJECT"), 5_000),
      max_ingest_keys: parse_int.(System.get_env("CLAUDE_NOTIFY_MEMORY_MAX_INGEST_KEYS"), 50_000),
      max_title_bytes: parse_int.(System.get_env("CLAUDE_NOTIFY_MEMORY_MAX_TITLE_BYTES"), 160),
      max_body_bytes: parse_int.(System.get_env("CLAUDE_NOTIFY_MEMORY_MAX_BODY_BYTES"), 2_000),
      max_metadata_entries:
        parse_int.(System.get_env("CLAUDE_NOTIFY_MEMORY_MAX_METADATA_ENTRIES"), 20),
      max_collection_entries:
        parse_int.(System.get_env("CLAUDE_NOTIFY_MEMORY_MAX_FILE_PATHS"), 50),
      max_handoff_summary_bytes:
        parse_int.(System.get_env("CLAUDE_NOTIFY_HANDOFF_MAX_SUMMARY_BYTES"), 4_000),
      max_handoff_item_bytes:
        parse_int.(System.get_env("CLAUDE_NOTIFY_HANDOFF_MAX_ITEM_BYTES"), 500),
      max_handoff_items: parse_int.(System.get_env("CLAUDE_NOTIFY_HANDOFF_MAX_ITEMS"), 20),
      max_context_bytes:
        parse_int.(System.get_env("CLAUDE_NOTIFY_MEMORY_MAX_CONTEXT_BYTES"), 8_000),
      max_page_bytes: parse_int.(System.get_env("CLAUDE_NOTIFY_MEMORY_MAX_PAGE_BYTES"), 12_000),
      max_search_results:
        parse_int.(System.get_env("CLAUDE_NOTIFY_MEMORY_MAX_SEARCH_RESULTS"), 8),
      max_search_snippet_bytes:
        parse_int.(System.get_env("CLAUDE_NOTIFY_MEMORY_MAX_SNIPPET_BYTES"), 700),
      max_briefing_bytes:
        parse_int.(System.get_env("CLAUDE_NOTIFY_MEMORY_MAX_BRIEFING_BYTES"), 6_000),
      conversation_max_pending:
        parse_int.(System.get_env("CLAUDE_NOTIFY_CONVERSATION_MAX_PENDING"), 10),
      conversation_max_prompt_bytes:
        parse_int.(System.get_env("CLAUDE_NOTIFY_CONVERSATION_MAX_PROMPT_BYTES"), 8_000)
    },
    preview: %{
      default_provider: System.get_env("CLAUDE_NOTIFY_PREVIEW_PROVIDER", "auto"),
      ttl_seconds:
        parse_int.(
          System.get_env("CLAUDE_NOTIFY_PREVIEW_TTL_SECONDS") ||
            System.get_env("CLOUDFLARE_PREVIEW_TTL_SECONDS"),
          7_200
        ),
      port_start: 41_000,
      port_end: 41_999,
      cloudflare: %{
        api_token: System.get_env("CLOUDFLARE_API_TOKEN"),
        account_id: System.get_env("CLOUDFLARE_ACCOUNT_ID"),
        zone_id: System.get_env("CLOUDFLARE_ZONE_ID"),
        domain: System.get_env("CLOUDFLARE_PREVIEW_DOMAIN"),
        allowed_emails: preview_emails,
        access_session_duration: System.get_env("CLOUDFLARE_ACCESS_SESSION_DURATION", "1h")
      },
      tailscale: %{
        mode: System.get_env("TAILSCALE_PREVIEW_MODE", "serve"),
        tailscale_path: System.get_env("TAILSCALE_PATH", "tailscale"),
        ssh_host: System.get_env("TAILSCALE_SSH_HOST"),
        ssh_path: System.get_env("TAILSCALE_SSH_PATH", "ssh"),
        https_port_start: 44_300,
        https_port_end: 44_399,
        remote_port_start: 45_300,
        remote_port_end: 45_399
      }
    },
    keep_awake_while_working: parse_bool.(System.get_env("CLAUDE_NOTIFY_KEEP_AWAKE"), true),
    max_event_concurrency: parse_int.(System.get_env("MAX_EVENT_CONCURRENCY"), 8),
    webhook_max_skew_seconds: parse_int.(System.get_env("WEBHOOK_MAX_SKEW_SECONDS"), 300)
end
