defmodule Shazam.Provider do
  @moduledoc """
  Behaviour for AI CLI providers.

  Each provider wraps a specific CLI tool (Claude Code, Codex, Cursor, Gemini)
  and normalizes the interface for Shazam's orchestration layer.

  ## Supported Providers

  | Provider | Module | CLI | Sessions |
  |----------|--------|-----|----------|
  | `claude_code` | `Shazam.Provider.ClaudeCode` | `claude` | Yes |
  | `codex` | `Shazam.Provider.Codex` | `codex` | No |
  | `cursor` | `Shazam.Provider.Cursor` | `cursor` | No |
  | `gemini` | `Shazam.Provider.Gemini` | `gemini` | No |

  ## Configuration

      # shazam.yaml
      provider: claude_code   # default for all agents

      agents:
        pm:
          role: Project Manager
          provider: claude_code
        senior_1:
          role: Senior Developer
          provider: codex        # uses Codex CLI
  """

  @type session :: pid() | reference() | any()
  @type result :: {:ok, String.t(), [String.t()]} | {:ok, String.t()} | {:error, any()}
  @type session_opts :: keyword()

  @doc "Start a persistent session (for providers that support it)."
  @callback start_session(session_opts()) :: {:ok, session()} | {:error, any()}

  @doc "Stop a session."
  @callback stop_session(session()) :: :ok

  @doc "Execute a prompt and return the result. Blocking call."
  @callback execute(session(), String.t(), keyword()) :: result()

  @doc "Whether this provider supports persistent sessions for reuse."
  @callback supports_sessions?() :: boolean()

  @doc "Human-readable name of the provider."
  @callback name() :: String.t()

  @doc "Check if the CLI binary is available on the system."
  @callback available?() :: boolean()
end
