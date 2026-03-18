defmodule Shazam.Backend.ClaudeCode do
  @moduledoc """
  Backend adapter for Claude Code SDK.
  Wraps the `claude_code` Elixir package for persistent sessions and streaming.
  """

  @behaviour Shazam.Backend

  require Logger

  # --- Behaviour Implementation ---

  @impl true
  def name, do: "Claude Code"

  @impl true
  def available? do
    case System.find_executable("claude") do
      nil -> false
      _ -> true
    end
  end

  @impl true
  def cli_version do
    case System.find_executable("claude") do
      nil ->
        nil
      path ->
        task = Task.async(fn ->
          System.cmd(path, ["--version"], stderr_to_stdout: true)
        end)
        case Task.yield(task, 3_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, {version, 0}} -> String.trim(version)
          _ -> nil
        end
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @impl true
  def supports_sessions?, do: true

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
  def stop_session(pid) do
    try do
      ClaudeCode.stop(pid)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @impl true
  def send_query(session, prompt) do
    touched_files = :ets.new(:touched_files, [:set, :private])

    stream = ClaudeCode.stream(session, prompt, include_partial_messages: true)

    stream =
      stream
      |> ClaudeCode.Stream.tap(fn message ->
        collect_touched_files(message, touched_files)
      end)

    result = ClaudeCode.Stream.final_result(stream)

    files = :ets.tab2list(touched_files) |> Enum.map(fn {path} -> path end)
    :ets.delete(touched_files)

    case result do
      %{is_error: true} = err -> {:error, err}
      %{result: text} -> {:ok, text, files}
      nil -> {:error, :no_result}
    end
  end

  @impl true
  def stream(session, prompt, opts \\ []) do
    include_partial = Keyword.get(opts, :include_partial, true)
    ClaudeCode.stream(session, prompt, include_partial_messages: include_partial)
  end

  @impl true
  def map_tool(tool), do: tool

  @impl true
  def build_session_opts(config) do
    [
      system_prompt: config.system_prompt,
      timeout: config.timeout,
      permission_mode: :bypass_permissions,
      setting_sources: ["user", "project"],
      env: %{"CLAUDECODE" => ""}
    ]
    |> maybe_add(:allowed_tools, config[:tools], config[:tools] not in [nil, []])
    |> maybe_add(:model, config[:model], config[:model] != nil)
    |> maybe_add(:cwd, config[:cwd], config[:cwd] != nil)
    |> maybe_add(:add_dir, config[:module_dirs], config[:module_dirs] not in [nil, []])
  end

  # --- Streaming Helpers (used by Orchestrator) ---

  @doc "Taps into a ClaudeCode stream to call a function on each message."
  def tap_stream(stream, fun) do
    ClaudeCode.Stream.tap(stream, fun)
  end

  @doc "Extracts the final result from a ClaudeCode stream."
  def final_result(stream) do
    ClaudeCode.Stream.final_result(stream)
  end

  @doc "Extracts text content chunks from a stream."
  def text_content(stream) do
    ClaudeCode.Stream.text_content(stream)
  end

  # --- Event Normalization ---

  @doc "Normalizes a ClaudeCode message into a Shazam internal event."
  def normalize_event(message) do
    alias ClaudeCode.Message
    alias ClaudeCode.Message.PartialAssistantMessage
    alias ClaudeCode.Content

    cond do
      match?(%PartialAssistantMessage{}, message) and PartialAssistantMessage.text_delta?(message) ->
        text = PartialAssistantMessage.get_text(message)
        {:text_delta, text || ""}

      match?(%Message.AssistantMessage{}, message) ->
        %Message.AssistantMessage{message: msg} = message
        events =
          Enum.map(msg.content, fn
            %Content.ToolUseBlock{name: tool_name, input: input} ->
              {:tool_use, tool_name, input}
            %Content.TextBlock{text: text} ->
              {:text, text}
            _ ->
              nil
          end)
          |> Enum.reject(&is_nil/1)
        {:assistant, events}

      match?(%Message.ResultMessage{}, message) ->
        %Message.ResultMessage{} = result_msg = message
        if result_msg.is_error do
          {:result_error, result_msg.result}
        else
          {:result_ok, result_msg.result}
        end

      true ->
        :ignore
    end
  rescue
    _ -> :ignore
  end

  # --- Private ---

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
        _ ->
          :ok
      end)
    end
  rescue
    _ -> :ok
  end

  defp maybe_add(opts, _key, _value, false), do: opts
  defp maybe_add(opts, key, value, true), do: Keyword.put(opts, key, value)
end
