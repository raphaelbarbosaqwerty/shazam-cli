defmodule Shazam.Backend.CursorCLITest do
  use ExUnit.Case, async: true

  alias Shazam.Backend.CursorCLI

  describe "normalize_event/1 (headless stream-json)" do
    test "assistant with message.content[].text" do
      ev = %{
        "type" => "assistant",
        "message" => %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Hello"}]
        }
      }

      assert CursorCLI.normalize_event(ev) == {:text_delta, "Hello"}
    end

    test "tool_call started readToolCall" do
      ev = %{
        "type" => "tool_call",
        "subtype" => "started",
        "tool_call" => %{"readToolCall" => %{"args" => %{"path" => "README.md"}}}
      }

      assert {:tool_use, "Read", %{"path" => "README.md"}} = CursorCLI.normalize_event(ev)
    end

    test "result success" do
      ev = %{
        "type" => "result",
        "subtype" => "success",
        "is_error" => false,
        "result" => "done"
      }

      assert CursorCLI.normalize_event(ev) == {:result_ok, "done"}
    end

    test "result error" do
      ev = %{"type" => "result", "is_error" => true, "result" => "quota exceeded"}
      assert CursorCLI.normalize_event(ev) == {:result_error, "quota exceeded"}
    end

    test "system init ignored" do
      assert CursorCLI.normalize_event(%{"type" => "system", "subtype" => "init"}) == :ignore
    end
  end

  describe "embed_system_in_user_prompt/2" do
    test "empty system returns user only" do
      assert CursorCLI.embed_system_in_user_prompt("", "task") == "task"
      assert CursorCLI.embed_system_in_user_prompt("   ", "x") == "x"
    end

    test "wraps both" do
      out = CursorCLI.embed_system_in_user_prompt("Be brief", "Do the thing")
      assert out =~ "Be brief"
      assert out =~ "Do the thing"
      assert out =~ "shazam_system_instructions"
    end
  end
end
