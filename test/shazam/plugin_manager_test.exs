defmodule Shazam.PluginManagerTest do
  use ExUnit.Case, async: false

  alias Shazam.PluginManager

  @moduletag :plugin_manager

  setup do
    ensure_started(Shazam.PluginManager)
    :ok
  end

  defp ensure_started(mod) do
    case GenServer.whereis(mod) do
      nil -> mod.start_link([])
      _pid -> :ok
    end
  end

  describe "run_pipeline/3" do
    test "returns {:ok, data} when no plugins are loaded" do
      # Ensure no plugins
      :persistent_term.put({Shazam.PluginManager, :plugins}, [])

      result = PluginManager.run_pipeline(:before_task_create, %{title: "test task"})
      assert result == {:ok, %{title: "test task"}}
    end

    test "passes data through unmodified with empty plugin list" do
      :persistent_term.put({Shazam.PluginManager, :plugins}, [])

      data = %{foo: "bar", count: 42}
      assert {:ok, ^data} = PluginManager.run_pipeline(:after_task_create, data)
    end
  end

  describe "list_plugins/0" do
    test "returns empty list initially" do
      # Reset persistent_term to ensure clean state
      :persistent_term.put({Shazam.PluginManager, :plugins}, [])

      result = PluginManager.list_plugins()
      assert is_list(result)
    end
  end

  describe "notify/3" do
    test "returns :ok when no plugins loaded" do
      :persistent_term.put({Shazam.PluginManager, :plugins}, [])

      result = PluginManager.notify(:after_task_complete, {"task_1", :ok})
      assert result == :ok
    end
  end
end
