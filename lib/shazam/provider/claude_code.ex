defmodule Shazam.Provider.ClaudeCode do
  @moduledoc """
  Provider implementation for Claude Code CLI.
  Supports persistent sessions via the `claude_code` Elixir package.
  """

  @behaviour Shazam.Provider

  require Logger

  @broadcast_batch_chars 200

  @impl true
  def name, do: "claude_code"

  @impl true
  def supports_sessions?, do: true

  @impl true
  def available? do
    Code.ensure_loaded?(ClaudeCode)
  end

  @impl true
  def start_session(opts) do
    child_spec = %{
      id: make_ref(),
      start: {ClaudeCode, :start_link, [opts]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(Shazam.AgentSupervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:session_start_failed, reason}}
    end
  end

  @impl true
  def stop_session(session) do
    ClaudeCode.stop(session)
    :ok
  rescue
    _ -> :ok
  end

  @impl true
  def execute(session, prompt, opts \\ []) do
    agent_name = Keyword.get(opts, :agent_name)

    touched_files = :ets.new(:touched_files, [:set, :private])
    Process.put(:text_delta_buffer, "")

    stream = ClaudeCode.stream(session, prompt, include_partial_messages: true)

    stream =
      if agent_name do
        stream
        |> ClaudeCode.Stream.tap(fn message ->
          broadcast_agent_event(agent_name, message)
          collect_touched_files(message, touched_files)
        end)
      else
        stream
      end

    result = ClaudeCode.Stream.final_result(stream)

    flush_text_buffer(agent_name)

    files = :ets.tab2list(touched_files) |> Enum.map(fn {path} -> path end)
    :ets.delete(touched_files)

    case result do
      %{is_error: true} = err -> {:error, err}
      %{result: text} -> {:ok, text, files}
      nil -> {:error, :no_result}
    end
  end

  @doc "Build session opts in ClaudeCode format."
  def build_session_opts(opts) do
    system_prompt = Keyword.get(opts, :system_prompt, "You are a helpful assistant.")
    timeout = Keyword.get(opts, :timeout, 300_000)
    tools = Keyword.get(opts, :tools, [])
    model = Keyword.get(opts, :model)
    workspace = Keyword.get(opts, :cwd)
    module_dirs = Keyword.get(opts, :add_dir, [])

    base = [
      system_prompt: system_prompt,
      timeout: timeout,
      permission_mode: :bypass_permissions,
      setting_sources: ["user", "project"],
      env: %{"CLAUDECODE" => ""}
    ]

    base
    |> maybe_add(:allowed_tools, if(tools != [], do: tools ++ ["Skill"], else: nil), tools != [])
    |> maybe_add(:model, model, model != nil)
    |> maybe_add(:cwd, workspace, workspace != nil)
    |> maybe_add(:add_dir, module_dirs, module_dirs != [])
  end

  # ── Event Broadcasting ─────────────────────────────────

  defp broadcast_agent_event(agent_name, message) do
    alias ClaudeCode.Message
    alias ClaudeCode.Message.PartialAssistantMessage
    alias ClaudeCode.Content

    # Tick pulse for sparkline tracking
    Shazam.AgentPulse.tick(agent_name)

    cond do
      match?(%PartialAssistantMessage{}, message) and PartialAssistantMessage.text_delta?(message) ->
        text = PartialAssistantMessage.get_text(message)
        buffer = (Process.get(:text_delta_buffer) || "") <> (text || "")

        if String.length(buffer) >= @broadcast_batch_chars do
          Shazam.API.EventBus.broadcast(%{
            event: "agent_output", agent: agent_name, type: "text_delta", content: buffer
          })
          Process.put(:text_delta_buffer, "")
        else
          Process.put(:text_delta_buffer, buffer)
        end

      match?(%Message.AssistantMessage{}, message) ->
        flush_text_buffer(agent_name)
        %Message.AssistantMessage{message: msg} = message
        Enum.each(msg.content, fn
          %Content.ToolUseBlock{name: tool_name, input: input} ->
            Shazam.API.EventBus.broadcast(%{
              event: "agent_output", agent: agent_name, type: "tool_use",
              content: "#{tool_name}: #{inspect(input, limit: 200)}"
            })
            # Notify plugin system
            Shazam.PluginManager.notify(:on_tool_use, {tool_name, input, agent_name})

          %Content.TextBlock{text: text} ->
            Shazam.API.EventBus.broadcast(%{
              event: "agent_output", agent: agent_name, type: "text", content: text
            })

          _ -> :ok
        end)

      match?(%Message.ResultMessage{}, message) ->
        %Message.ResultMessage{} = result_msg = message
        usage = result_msg.usage || %{}
        input_tokens = usage[:input_tokens] || 0
        output_tokens = usage[:output_tokens] || 0
        total_tokens = input_tokens + output_tokens
        cost_usd = result_msg.total_cost_usd || 0.0

        Shazam.Metrics.record_tokens(agent_name, total_tokens, cost_usd)

        Shazam.API.EventBus.broadcast(%{
          event: "agent_output", agent: agent_name, type: "text",
          content: "Tokens: #{total_tokens} (in: #{input_tokens}, out: #{output_tokens}) | Cost: $#{Float.round(cost_usd, 4)}"
        })

        content = if result_msg.is_error do
          "Failed: #{result_msg.result |> inspect(limit: 200) |> String.slice(0, 300)}"
        else
          "Completed"
        end

        Shazam.API.EventBus.broadcast(%{
          event: "agent_output", agent: agent_name, type: "result", content: content
        })

      true -> :ok
    end
  rescue
    _ -> :ok
  end

  defp collect_touched_files(message, table) do
    alias ClaudeCode.Message
    alias ClaudeCode.Content

    if match?(%Message.AssistantMessage{}, message) do
      %Message.AssistantMessage{message: msg} = message
      Enum.each(msg.content, fn
        %Content.ToolUseBlock{name: tool_name, input: input}
            when tool_name in ["Edit", "Write"] ->
          path = input["file_path"] || input[:file_path]
          if path, do: :ets.insert(table, {path})
        _ -> :ok
      end)
    end
  rescue
    _ -> :ok
  end

  defp flush_text_buffer(agent_name) do
    buffer = Process.get(:text_delta_buffer) || ""
    if buffer != "" do
      Shazam.API.EventBus.broadcast(%{
        event: "agent_output", agent: agent_name, type: "text_delta", content: buffer
      })
      Process.put(:text_delta_buffer, "")
    end
  end

  defp maybe_add(opts, _key, _value, false), do: opts
  defp maybe_add(opts, key, value, true), do: Keyword.put(opts, key, value)
end
