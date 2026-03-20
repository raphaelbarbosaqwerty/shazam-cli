import Config

# Use a random port for tests to avoid conflicts
config :shazam, port: 0

# Suppress all logging in tests
config :logger, level: :none
