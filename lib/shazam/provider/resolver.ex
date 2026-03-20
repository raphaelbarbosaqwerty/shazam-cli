defmodule Shazam.Provider.Resolver do
  @moduledoc """
  Resolves provider name (string/atom) to the provider module.
  """

  @providers %{
    "claude_code" => Shazam.Provider.ClaudeCode,
    "claude" => Shazam.Provider.ClaudeCode,
    "codex" => Shazam.Provider.Codex,
    "cursor" => Shazam.Provider.Cursor,
    "gemini" => Shazam.Provider.Gemini
  }

  @doc "Resolve a provider name to its module. Defaults to ClaudeCode."
  def resolve(nil), do: Shazam.Provider.ClaudeCode
  def resolve(""), do: Shazam.Provider.ClaudeCode

  def resolve(name) when is_atom(name) do
    # Check if it's already a module
    if function_exported?(name, :name, 0) do
      name
    else
      resolve(Atom.to_string(name))
    end
  end

  def resolve(name) when is_binary(name) do
    Map.get(@providers, String.downcase(name), Shazam.Provider.ClaudeCode)
  end

  @doc "List all available provider names."
  def available_providers do
    @providers
    |> Map.values()
    |> Enum.uniq()
    |> Enum.filter(fn mod ->
      Code.ensure_loaded?(mod) and mod.available?()
    end)
    |> Enum.map(& &1.name())
  end
end
