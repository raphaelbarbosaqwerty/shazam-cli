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

# Phoenix Endpoint
config :shazam, ShazamWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4040],
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ShazamWeb.ErrorHTML, json: ShazamWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Shazam.PubSub,
  secret_key_base: "shazam-cli-secret-key-base-that-is-at-least-64-bytes-long-for-production-use!!",
  live_view: [signing_salt: "shazam_lv_salt"],
  server: true,
  check_origin: false

# esbuild
config :esbuild,
  version: "0.21.5",
  shazam: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Tailwind
config :tailwind,
  version: "3.4.13",
  shazam: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Import environment-specific config
import_config "#{config_env()}.exs"
