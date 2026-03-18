defmodule Shazam.StoreTest do
  use ExUnit.Case, async: false

  alias Shazam.Store

  @test_prefix "test_store_"

  setup do
    # Ensure JSON backend for tests (no SQLite dependency)
    Application.put_env(:shazam, :store_backend, :json)
    Store.init()

    on_exit(fn ->
      # Clean up test keys
      Store.list_keys(@test_prefix)
      |> Enum.each(&Store.delete/1)
    end)

    :ok
  end

  defp test_key(suffix), do: "#{@test_prefix}#{suffix}"

  # ── save/2 and load/1 ───────────────────────────────────

  describe "save/2 and load/1" do
    test "saves and loads a simple map" do
      key = test_key("map")
      Store.save(key, %{"hello" => "world"})

      assert {:ok, %{"hello" => "world"}} = Store.load(key)
    end

    test "saves and loads a list" do
      key = test_key("list")
      Store.save(key, [1, 2, 3])

      assert {:ok, [1, 2, 3]} = Store.load(key)
    end

    test "saves and loads nested data" do
      key = test_key("nested")
      data = %{"users" => [%{"name" => "Alice", "age" => 30}]}
      Store.save(key, data)

      assert {:ok, ^data} = Store.load(key)
    end

    test "overwrites existing data" do
      key = test_key("overwrite")
      Store.save(key, %{"v" => 1})
      Store.save(key, %{"v" => 2})

      assert {:ok, %{"v" => 2}} = Store.load(key)
    end

    test "loading non-existent key returns error" do
      assert {:error, :not_found} = Store.load("nonexistent_key_abc123")
    end
  end

  # ── delete/1 ─────────────────────────────────────────────

  describe "delete/1" do
    test "removes a saved key" do
      key = test_key("deleteme")
      Store.save(key, %{"data" => true})
      Store.delete(key)

      assert {:error, :not_found} = Store.load(key)
    end

    test "deleting non-existent key is safe" do
      # Should not raise
      Store.delete("nonexistent_key_xyz")
    end
  end

  # ── list_keys/1 ─────────────────────────────────────────

  describe "list_keys/1" do
    test "lists keys with matching prefix" do
      Store.save(test_key("alpha"), %{})
      Store.save(test_key("beta"), %{})

      keys = Store.list_keys(@test_prefix)
      assert length(keys) >= 2
      assert Enum.all?(keys, &String.starts_with?(&1, @test_prefix))
    end

    test "returns empty list for non-matching prefix" do
      assert Store.list_keys("zzz_nonexistent_prefix_") == []
    end

    test "does not return keys with different prefix" do
      Store.save(test_key("scoped"), %{})

      keys = Store.list_keys("other_prefix_")
      refute Enum.any?(keys, &String.contains?(&1, @test_prefix))
    end
  end

  # ── init/0 ───────────────────────────────────────────────

  describe "init/0" do
    test "creates the data directory" do
      Store.init()
      assert File.dir?(Store.data_dir())
    end
  end

  # ── Round-trip with special characters ───────────────────

  describe "key sanitization" do
    test "keys with colons are safe" do
      key = test_key("tasks:company_a")
      Store.save(key, [%{"id" => 1}])

      assert {:ok, [%{"id" => 1}]} = Store.load(key)
    end

    test "keys with hyphens are safe" do
      key = test_key("my-project-config")
      Store.save(key, %{"ok" => true})

      assert {:ok, %{"ok" => true}} = Store.load(key)
    end
  end
end
