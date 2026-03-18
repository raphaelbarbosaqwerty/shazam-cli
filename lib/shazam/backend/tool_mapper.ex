defmodule Shazam.Backend.ToolMapper do
  @moduledoc """
  Maps canonical Shazam tool names to backend-specific names.
  Shazam uses Claude Code tool names as the canonical set.
  """

  @doc "Maps a list of tool names for the given backend."
  def map_tools(tools, backend_module) when is_list(tools) do
    Enum.map(tools, &backend_module.map_tool/1)
  end

  @doc "Maps a single tool name for the current backend."
  def map_tool(tool) do
    Shazam.Backend.Registry.current().map_tool(tool)
  end

  @doc "Returns the canonical tool name from a backend-specific name."
  def reverse_map(backend_tool, backend_module) do
    canonical()
    |> Enum.find(fn tool -> backend_module.map_tool(tool) == backend_tool end)
    |> Kernel.||(backend_tool)
  end

  @doc "List of all canonical tool names (Claude Code format)."
  def canonical do
    [
      "Read", "Edit", "Write", "Bash", "Grep", "Glob",
      "WebSearch", "WebFetch", "Skill", "TodoWrite"
    ]
  end
end
