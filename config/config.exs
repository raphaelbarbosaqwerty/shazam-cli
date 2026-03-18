import Config

config :shazam,
  codex_fallback_enabled: true,
  codex_fallback_model: System.get_env("CODEX_FALLBACK_MODEL") || "gpt-5-codex",
  codex_cli_bin: System.get_env("CODEX_CLI_BIN") || "codex",
  codex_fallback_timeout_ms: 1_800_000,
  codex_progress_interval_ms: 15_000

# Use system-installed Claude CLI (required for escript — bundled mode can't write to escript archive)
config :claude_code, cli_path: :global

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]
