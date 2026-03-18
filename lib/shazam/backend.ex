defmodule Shazam.Backend do
  @moduledoc """
  Behaviour that all AI CLI backends must implement.
  Provides a unified interface for session management, streaming, and querying.
  """

  @type session :: any()
  @type session_opts :: keyword()

  @doc "Human-readable name of the backend (e.g. \"Claude Code\", \"Cursor CLI\")."
  @callback name() :: String.t()

  @doc "Checks if the backend CLI binary is available in the system PATH."
  @callback available?() :: boolean()

  @doc "Returns the version string of the installed CLI, or nil."
  @callback cli_version() :: String.t() | nil

  @doc "Whether this backend supports persistent sessions across tasks."
  @callback supports_sessions?() :: boolean()

  @doc "Starts a new session (or returns a virtual ref for stateless backends)."
  @callback start_session(session_opts()) :: {:ok, session()} | {:error, any()}

  @doc "Stops/cleans up a session."
  @callback stop_session(session()) :: :ok

  @doc "Sends a prompt and returns the full result (blocking)."
  @callback send_query(session(), prompt :: String.t()) ::
              {:ok, text :: String.t(), touched_files :: [String.t()]} | {:error, any()}

  @doc "Streams events from the backend for real-time output."
  @callback stream(session(), prompt :: String.t(), opts :: keyword()) :: Enumerable.t()

  @doc """
  Maps canonical Shazam tool names to backend-specific names.
  e.g. "Bash" -> "Shell" for Cursor CLI.
  """
  @callback map_tool(tool_name :: String.t()) :: String.t()

  @doc """
  Builds backend-specific session options from a canonical config map.
  Each backend translates the common config into its own format.
  """
  @callback build_session_opts(config :: map()) :: session_opts()
end
