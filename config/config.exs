import Config

# AI Backend configuration
config :shazam,
  backend: String.to_atom(System.get_env("SHAZAM_BACKEND") || "claude_code"),
  fallback_backend: nil,
  cursor_cli_bin: System.get_env("CURSOR_CLI_BIN") || "agent",
  cursor_api_key: System.get_env("CURSOR_API_KEY"),
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

if config_env() == :test do
  config :shazam, :port, 14_040
end
