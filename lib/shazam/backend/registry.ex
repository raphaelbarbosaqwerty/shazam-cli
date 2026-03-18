defmodule Shazam.Backend.Registry do
  @moduledoc """
  Resolves the active backend module from configuration.
  Supports runtime switching and auto-detection.
  """

  require Logger

  @backends %{
    claude_code: Shazam.Backend.ClaudeCode,
    cursor_cli: Shazam.Backend.CursorCLI
  }

  @doc "Returns the currently configured backend module."
  def current do
    Application.get_env(:shazam, :backend, :claude_code)
    |> resolve()
  end

  @doc "Returns the fallback backend module, or nil if none configured."
  def fallback do
    case Application.get_env(:shazam, :fallback_backend) do
      nil -> nil
      key -> resolve(key)
    end
  end

  @doc "Resolves a backend key (atom) to its module."
  def resolve(key) when is_atom(key) do
    Map.get(@backends, key, Shazam.Backend.ClaudeCode)
  end

  def resolve(key) when is_binary(key) do
    key |> String.to_existing_atom() |> resolve()
  rescue
    _ -> Shazam.Backend.ClaudeCode
  end

  @doc "Returns all registered backend keys."
  def all_keys, do: Map.keys(@backends)

  @doc "Returns all registered backend modules."
  def all_modules, do: Map.values(@backends)

  @doc "Returns a map of %{key => module} for all backends."
  def all, do: @backends

  @doc "Detects which backends are available on this system."
  def detect_available do
    @backends
    |> Enum.filter(fn {_key, mod} -> mod.available?() end)
    |> Enum.map(fn {key, mod} ->
      %{
        key: key,
        module: mod,
        name: mod.name(),
        version: mod.cli_version(),
        sessions: mod.supports_sessions?()
      }
    end)
  end

  @doc "Sets the active backend at runtime."
  def set_backend(key) when is_atom(key) do
    if Map.has_key?(@backends, key) do
      Application.put_env(:shazam, :backend, key)
      Logger.info("[Backend] Switched to #{resolve(key).name()}")
      :ok
    else
      {:error, {:unknown_backend, key}}
    end
  end
end
