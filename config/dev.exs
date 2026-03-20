import Config

config :shazam, ShazamWeb.Endpoint,
  check_origin: false,
  code_reloader: false,
  debug_errors: true,
  secret_key_base: "dev-only-secret-key-base-that-is-at-least-64-bytes-long-for-shazam-dev-environment!!",
  watchers: []
