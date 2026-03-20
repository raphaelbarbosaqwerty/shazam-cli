import Config

# Use a random port for tests to avoid conflicts
config :shazam, port: 0

# Suppress all logging in tests
config :logger, level: :none

config :shazam, ShazamWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-only-secret-key-base-that-is-at-least-64-bytes-long-for-shazam-test-environment!!",
  server: false
