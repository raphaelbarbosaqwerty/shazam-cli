defmodule Shazam.Backend.CursorCLI do
  @moduledoc """
  Backend adapter for Cursor CLI headless mode (`agent`).

  Follows the official **headless / print** flow:
  [Using Headless CLI](https://cursor.com/docs/cli/headless):

  - `agent -p --force` — non-interactive runs with permission to edit files
  - `--output-format json` | `stream-json` (+ optional `--stream-partial-output`)
  - Auth: `agent login` or `CURSOR_API_KEY` for scripts ([docs](https://cursor.com/docs/cli/headless))

  ## System instructions

  Headless mode passes **one user prompt string**; there is no separate system API in the docs.
  Shazam embeds agent system instructions inside that prompt (teams often block `--system-prompt`).

  Opt-in to `--system-prompt` + temp file (if your org allows):

      export CURSOR_CLI_USE_SYSTEM_PROMPT_FILE=1
  """

  @behaviour Shazam.Backend

  require Logger

  @default_timeout 1_800_000

  # Tool name mapping: Shazam canonical -> Cursor CLI
  @tool_map %{
    "Bash" => "Shell",
    "Edit" => "StrReplace"
  }

  # Model mapping: Claude/external names -> Cursor CLI equivalents
  @model_map %{
    "claude-haiku-4-5-20251001" => "sonnet-4.6",
    "claude-sonnet-4-20250514" => "sonnet-4.6",
    "claude-sonnet-4.5" => "sonnet-4.5",
    "claude-opus-4" => "opus-4.6",
    "claude-3-5-sonnet" => "sonnet-4.5",
    "claude-3-5-haiku" => "sonnet-4.6",
    "claude-3-opus" => "opus-4.5"
  }

  # --- Behaviour Implementation ---

  @impl true
  def name, do: "Cursor CLI"

  @impl true
  def available? do
    cli_bin() |> System.find_executable() != nil
  end

  @impl true
  def cli_version do
    bin = cli_bin()
    case System.find_executable(bin) do
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
  def supports_sessions?, do: false

  @impl true
  def start_session(opts) do
    ref = make_ref()
    model = Keyword.get(opts, :model)
    cwd = Keyword.get(opts, :cwd)
    Logger.info("[CursorCLI] Session created (ref=#{inspect(ref)}, model=#{model || "default"}, cwd=#{cwd || "nil"})")
    {:ok, %{ref: ref, opts: opts}}
  end

  @impl true
  def stop_session(%{port: port}) when not is_nil(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
    :ok
  end
  def stop_session(_), do: :ok

  @impl true
  def send_query(session, prompt) do
    opts = session[:opts] || []
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    args = build_cli_args(session, prompt, :json)

    bin = resolve_bin!()
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    model = Keyword.get(opts, :model)
    prompt_preview = String.slice(prompt, 0, 120)

    Logger.info("[CursorCLI] ── Query Start ──")
    Logger.info("[CursorCLI]   bin: #{bin}")
    Logger.info("[CursorCLI]   cwd: #{cwd}")
    Logger.info("[CursorCLI]   model: #{model || "default"}")
    Logger.info("[CursorCLI]   timeout: #{div(timeout, 1000)}s")
    Logger.info("[CursorCLI]   prompt: #{prompt_preview}...")
    Logger.info("[CursorCLI]   args: #{inspect(args, limit: 300)}")

    started_at = System.monotonic_time(:millisecond)

    task = Task.async(fn ->
      System.cmd(bin, args, stderr_to_stdout: true, cd: cwd)
    end)

    result = case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        elapsed = System.monotonic_time(:millisecond) - started_at
        Logger.info("[CursorCLI] ── Query OK (#{elapsed}ms) ──")
        Logger.info("[CursorCLI]   output size: #{byte_size(output)} bytes")
        Logger.info("[CursorCLI]   output preview: #{String.slice(output, 0, 300)}")
        parse_json_result(output)

      {:ok, {output, status}} ->
        elapsed = System.monotonic_time(:millisecond) - started_at
        Logger.error("[CursorCLI] ── Query FAILED (#{elapsed}ms, exit=#{status}) ──")
        Logger.error("[CursorCLI]   output: #{String.slice(output, 0, 500)}")
        {:error, {:cursor_exit, status, String.slice(output, 0, 2_000)}}

      nil ->
        Logger.error("[CursorCLI] ── Query TIMEOUT (#{div(timeout, 1000)}s) ──")
        {:error, {:cursor_timeout, timeout}}
    end

    if system_prompt_file_mode?(), do: cleanup_temp_system_prompts()
    result
  end

  @impl true
  def stream(session, prompt, _opts \\ []) do
    Stream.resource(
      fn -> start_stream(session, prompt) end,
      &receive_stream/1,
      &cleanup_stream/1
    )
  end

  @impl true
  def map_tool(tool) do
    Map.get(@tool_map, tool, tool)
  end

  @impl true
  def build_session_opts(config) do
    [
      system_prompt: config.system_prompt,
      timeout: config[:timeout] || @default_timeout,
      cwd: config[:cwd],
      model: config[:model],
      tools: map_tools(config[:tools] || [])
    ]
  end

  # --- Event Normalization ---
  # Matches Cursor stream-json schema:
  # https://cursor.com/docs/cli/reference/output-format

  @doc "Normalizes a Cursor NDJSON event into a Shazam internal event."
  def normalize_event(%{"type" => "system"}), do: :ignore
  def normalize_event(%{"type" => "user"}), do: :ignore

  def normalize_event(%{"type" => "assistant"} = ev) do
    case assistant_text(ev) do
      t when is_binary(t) and t != "" -> {:text_delta, t}
      _ -> :ignore
    end
  end

  def normalize_event(%{"type" => "tool_call", "subtype" => "started", "tool_call" => tc}) do
    {tool, input} = summarize_tool_started(tc)
    {:tool_use, tool, input}
  end

  def normalize_event(%{"type" => "tool_call", "subtype" => "completed", "tool_call" => tc}) do
    {tool, out} = summarize_tool_completed(tc)
    if tool, do: {:tool_complete, tool, out}, else: :ignore
  end

  # Legacy stream-json shapes (older CLI)
  def normalize_event(%{"type" => "assistant", "content" => content}) when is_binary(content) do
    {:text_delta, content}
  end

  def normalize_event(%{"type" => "tool_call", "status" => "start", "tool" => tool, "input" => input}) do
    {:tool_use, tool, input}
  end

  def normalize_event(%{"type" => "tool_call", "status" => "complete", "tool" => tool, "output" => output}) do
    {:tool_complete, tool, output}
  end

  def normalize_event(%{"type" => "result"} = ev) do
    text = ev["result"] || ev["content"] || ""

    if ev["is_error"] == true do
      {:result_error, text}
    else
      {:result_ok, text}
    end
  end

  def normalize_event(%{"type" => "error", "message" => msg}) do
    {:result_error, msg}
  end

  def normalize_event(_), do: :ignore

  defp assistant_text(%{"message" => %{"content" => parts}}) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{"type" => "text", "text" => t} when is_binary(t) -> t
      %{"text" => t} when is_binary(t) -> t
      _ -> ""
    end)
    |> IO.iodata_to_binary()
  end

  defp assistant_text(%{"content" => c}) when is_binary(c), do: c
  defp assistant_text(_), do: nil

  defp summarize_tool_started(tc) do
    cond do
      p = get_in(tc, ["readToolCall", "args", "path"]) ->
        {"Read", %{"path" => p}}

      p = get_in(tc, ["writeToolCall", "args", "path"]) ->
        {"Write", %{"path" => p}}

      f = tc["function"] ->
        {f["name"] || "function", %{"arguments" => f["arguments"]}}

      true ->
        {"tool", tc}
    end
  end

  defp summarize_tool_completed(tc) do
    cond do
      get_in(tc, ["readToolCall", "result"]) ->
        lines = get_in(tc, ["readToolCall", "result", "success", "totalLines"])
        path = get_in(tc, ["readToolCall", "args", "path"])
        {"Read", "read #{path}" <> if(lines, do: " (#{lines} lines)", else: "")}

      s = get_in(tc, ["writeToolCall", "result", "success"]) ->
        p = s["path"] || get_in(tc, ["writeToolCall", "args", "path"])
        lines = s["linesCreated"]
        {"Write", "wrote #{p}" <> if(lines, do: " (#{lines} lines)", else: "")}

      true ->
        {nil, nil}
    end
  end

  # --- Private ---

  defp start_stream(session, prompt) do
    opts = session[:opts] || []
    args = build_cli_args(session, prompt, :stream_json)
    bin = resolve_bin!()
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    prompt_preview = String.slice(prompt, 0, 120)

    Logger.info("[CursorCLI] ── Stream Start ──")
    Logger.info("[CursorCLI]   bin: #{bin}")
    Logger.info("[CursorCLI]   cwd: #{cwd}")
    Logger.info("[CursorCLI]   prompt: #{prompt_preview}...")
    Logger.info("[CursorCLI]   args: #{inspect(args, limit: 300)}")

    port = Port.open(
      {:spawn_executable, bin},
      [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: args,
        cd: cwd
      ]
    )

    Logger.info("[CursorCLI]   port: #{inspect(port)} — waiting for events...")
    %{port: port, buffer: "", event_count: 0, started_at: System.monotonic_time(:millisecond)}
  end

  defp receive_stream(%{port: port, buffer: buffer} = state) do
    receive do
      {^port, {:data, data}} ->
        new_buffer = buffer <> data
        {events, remaining} = parse_ndjson_buffer(new_buffer)
        new_count = state.event_count + length(events)

        if events != [] do
          Logger.info("[CursorCLI]   received #{length(events)} event(s) (total: #{new_count})")
        end

        {events, %{state | buffer: remaining, event_count: new_count}}

      {^port, {:exit_status, 0}} ->
        elapsed = System.monotonic_time(:millisecond) - state.started_at
        {remaining_events, _} = parse_ndjson_buffer(buffer)
        Logger.info("[CursorCLI] ── Stream OK (#{elapsed}ms, #{state.event_count + length(remaining_events)} events) ──")
        {remaining_events, :done}

      {^port, {:exit_status, status}} ->
        elapsed = System.monotonic_time(:millisecond) - state.started_at
        Logger.warning("[CursorCLI] ── Stream FAILED (#{elapsed}ms, exit=#{status}) ──")
        Logger.warning("[CursorCLI]   remaining buffer: #{String.slice(buffer, 0, 500)}")
        {:halt, :done}
    after
      60_000 ->
        Logger.warning("[CursorCLI] ── Stream TIMEOUT (60s no data) ──")
        {:halt, :done}
    end
  end
  defp receive_stream(:done), do: {:halt, :done}

  defp cleanup_stream(:done) do
    if system_prompt_file_mode?(), do: cleanup_temp_system_prompts()
    :ok
  end
  defp cleanup_stream(%{port: port}) do
    if system_prompt_file_mode?(), do: cleanup_temp_system_prompts()
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end

  defp parse_ndjson_buffer(buffer) do
    lines = String.split(buffer, "\n")
    {complete, [remaining]} = Enum.split(lines, -1)

    events =
      complete
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn line ->
        case Jason.decode(line) do
          {:ok, event} -> normalize_event(event)
          {:error, _} ->
            Logger.debug("[CursorCLI] Unparseable line: #{String.slice(line, 0, 200)}")
            :ignore
        end
      end)
      |> Enum.reject(&(&1 == :ignore))

    {events, remaining}
  end

  defp parse_json_result(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, %{"type" => "result", "is_error" => true} = data} ->
        {:error, {:cursor_result_error, Map.get(data, "result", "error")}}

      {:ok, %{"type" => "result", "result" => text}} when is_binary(text) ->
        {:ok, text, []}

      {:ok, %{"result" => text}} when is_binary(text) ->
        {:ok, text, []}

      {:ok, %{"content" => text}} when is_binary(text) ->
        {:ok, text, []}

      {:ok, data} when is_map(data) ->
        text = Map.get(data, "result", Map.get(data, "content", inspect(data)))
        {:ok, to_string(text), []}

      {:error, _} ->
        {:ok, String.trim(output), []}
    end
  end

  defp system_prompt_file_mode? do
    System.get_env("CURSOR_CLI_USE_SYSTEM_PROMPT_FILE") in ~w(1 true yes on)
  end

  @doc false
  def embed_system_in_user_prompt(system_prompt, user_prompt) do
    sys = String.trim(to_string(system_prompt || ""))
    user = user_prompt || ""

    if sys == "" do
      user
    else
      """
      <shazam_system_instructions>
      #{sys}
      </shazam_system_instructions>

      Follow the instructions in <shazam_system_instructions> above. Then complete:

      <shazam_task>
      #{user}
      </shazam_task>
      """
      |> String.trim()
    end
  end

  defp build_cli_args(session, prompt, format) do
    opts = session[:opts] || []
    model = Keyword.get(opts, :model)
    system_prompt = Keyword.get(opts, :system_prompt)

    {user_message, system_args} =
      cond do
        system_prompt_file_mode?() && system_prompt && String.trim(system_prompt) != "" ->
          case write_temp_system_prompt(system_prompt) do
            nil ->
              Logger.warning("[CursorCLI] Temp system prompt file failed; embedding in message instead")
              {embed_system_in_user_prompt(system_prompt, prompt), []}

            path ->
              Logger.info("[CursorCLI] Using --system-prompt file (CURSOR_CLI_USE_SYSTEM_PROMPT_FILE)")
              {prompt, ["--system-prompt", path]}
          end

        true ->
          {embed_system_in_user_prompt(system_prompt, prompt), []}
      end

    base_args = ["-p", "--force"]

    format_args = case format do
      :json -> ["--output-format", "json"]
      :stream_json -> ["--output-format", "stream-json", "--stream-partial-output"]
    end

    mapped_model = map_model(model)
    model_args = if mapped_model, do: ["--model", mapped_model], else: []

    base_args ++ format_args ++ model_args ++ system_args ++ [user_message]
  end

  defp map_model(nil), do: nil
  defp map_model(model) do
    model_str = to_string(model)
    case Map.get(@model_map, model_str) do
      nil ->
        if String.starts_with?(model_str, "claude") do
          Logger.warning("[CursorCLI] Unknown Claude model '#{model_str}', falling back to 'auto'")
          "auto"
        else
          model_str
        end
      mapped ->
        Logger.info("[CursorCLI] Mapped model '#{model_str}' -> '#{mapped}'")
        mapped
    end
  end

  defp write_temp_system_prompt(text) do
    dir = Path.join(System.tmp_dir!(), "shazam")
    File.mkdir_p!(dir)
    path = Path.join(dir, "system_prompt_#{System.unique_integer([:positive])}.md")
    case File.write(path, text) do
      :ok -> path
      {:error, _} -> nil
    end
  end

  defp cleanup_temp_system_prompts do
    dir = Path.join(System.tmp_dir!(), "shazam")
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.starts_with?(&1, "system_prompt_"))
        |> Enum.each(fn f -> File.rm(Path.join(dir, f)) end)
      _ -> :ok
    end
  end

  defp map_tools(tools) when is_list(tools) do
    Enum.map(tools, &map_tool/1)
  end

  defp cli_bin do
    Application.get_env(:shazam, :cursor_cli_bin, "agent")
  end

  defp resolve_bin! do
    bin = cli_bin()
    case System.find_executable(bin) do
      nil -> raise "Cursor CLI binary '#{bin}' not found in PATH"
      path -> path
    end
  end
end
