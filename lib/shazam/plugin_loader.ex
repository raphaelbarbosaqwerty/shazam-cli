defmodule Shazam.PluginLoader do
  @moduledoc """
  Discovers and compiles plugin `.ex` files from `.shazam/plugins/`.
  """

  require Logger

  @plugin_dir ".shazam/plugins"

  @doc "Compile all `.ex` files in the plugins directory. Returns list of modules."
  def load_all(workspace) do
    dir = Path.join(workspace, @plugin_dir)

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".ex"))
      |> Enum.sort()
      |> Enum.flat_map(fn file ->
        compile_plugin(Path.join(dir, file))
      end)
    else
      []
    end
  end

  @doc "Compile a single plugin file. Returns list of plugin modules."
  def compile_plugin(path) do
    Code.compile_file(path)
    |> Enum.filter(fn {mod, _binary} ->
      behaviours = mod.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
      Shazam.Plugin in behaviours
    end)
    |> Enum.map(fn {mod, _binary} -> mod end)
  rescue
    e ->
      Logger.error("[PluginLoader] Failed to compile #{path}: #{Exception.message(e)}")
      []
  catch
    kind, reason ->
      Logger.error("[PluginLoader] #{kind} compiling #{path}: #{inspect(reason)}")
      []
  end
end
