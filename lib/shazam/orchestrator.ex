defmodule Shazam.Orchestrator do
  @moduledoc """
  Coordinates the execution of multiple AI agents in parallel or in pipeline.
  Backend-agnostic — delegates to the active backend via Shazam.Backend.Registry.
  """

  require Logger

  alias Shazam.Backend.{Registry, EventNormalizer}

  @default_timeout 300_000
  @default_system_prompt "You are a specialized assistant. Be direct and objective."
  @default_codex_fallback_model "gpt-5-codex"
  @default_codex_fallback_timeout_ms 1_800_000
  @default_codex_progress_interval_ms 15_000

  @broadcast_batch_chars 200

  @doc "Executes agents in parallel (fan-out) and collects results (fan-in)."
  def run(agents, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
    stream? = Keyword.get(opts, :stream, false)

    Logger.info("Starting #{length(agents)} agent(s) with max concurrency of #{max_concurrency}")

    results =
      agents
      |> Task.async_stream(
        fn agent -> execute_agent(agent, stream?, timeout) end,
        max_concurrency: max_concurrency,
        timeout: timeout + 5_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, :timeout} -> {:error, :timeout}
      end)

    aggregate_results(agents, results)
  end

  @doc "Executes agents sequentially in pipeline."
  def pipeline(agents, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    stream? = Keyword.get(opts, :stream, false)

    Logger.info("Starting pipeline with #{length(agents)} stage(s)")

    agents
    |> Enum.reduce({nil, []}, fn agent, {prev_output, history} ->
      prompt = resolve_prompt(agent, prev_output)
      agent = Map.put(agent, :prompt, prompt)

      Logger.info("[pipeline] Executing: #{agent[:name] || "unnamed"}")

      result = execute_agent(agent, stream?, timeout)

      case result do
        {:ok, output} ->
          {output, history ++ [{agent[:name], output}]}

        {:error, reason} ->
          Logger.error("[pipeline] Failed at #{agent[:name]}: #{inspect(reason)}")
          {prev_output, history ++ [{agent[:name], {:error, reason}}]}
      end
    end)
    |> then(fn {final_output, history} ->
      %{final_output: final_output, history: history}
    end)
  end

  @doc """
  Executes a query on an existing session (from SessionPool).
  Does NOT create or destroy the session — the pool manages its lifecycle.
  """
  def execute_on_session(session, agent_name, prompt) do
    backend = Registry.current()

    try do
      result = execute_query_on_backend(backend, session, prompt, agent_name)

      case result do
        {:ok, text, files} -> {:ok, text, files}
        other -> other
      end
    rescue
      e ->
        Logger.error("[#{agent_name}] Error on pooled session: #{inspect(e)}")
        {:error, e}
    end
  end

  # --- Private: Agent Execution ---

  defp execute_agent(agent, stream?, timeout) do
    backend = Registry.current()
    name = agent[:name] || "agent"
    prompt = agent[:prompt]
    system_prompt = agent[:system_prompt] || @default_system_prompt
    tools = agent[:tools] || []
    model = agent[:model]
    fallback_model = resolve_fallback_model(agent)
    modules = agent[:modules] || []

    workspace = Application.get_env(:shazam, :workspace, nil)

    module_dirs =
      if workspace && modules != [] do
        modules
        |> Enum.map(fn m -> Path.join(workspace, m["path"] || "") end)
        |> Enum.filter(&File.dir?/1)
      else
        []
      end

    config = %{
      system_prompt: system_prompt,
      timeout: timeout,
      cwd: workspace,
      model: model,
      tools: tools,
      module_dirs: module_dirs
    }

    session_opts = backend.build_session_opts(config)

    Logger.info("[#{name}] Starting session on #{backend.name()}...")

    case execute_on_backend(backend, session_opts, stream?, name, prompt) do
      {:error, reason} = error ->
        maybe_fallback(error, reason, name, prompt, system_prompt, fallback_model, timeout)
      result ->
        result
    end
  end

  defp execute_on_backend(backend, session_opts, stream?, name, prompt) do
    with {:ok, session} <- backend.start_session(session_opts) do
      try do
        result =
          if stream? do
            execute_stream_on_backend(backend, session, name, prompt)
          else
            execute_query_on_backend(backend, session, prompt, name)
          end

        backend.stop_session(session)

        case result do
          {:ok, text, files} -> {:ok, text, files}
          {:ok, text} -> {:ok, text, []}
          other -> other
        end
      rescue
        e ->
          backend.stop_session(session)
          Logger.error("[#{name}] Error: #{inspect(e)}")
          {:error, e}
      end
    end
  end

  defp execute_query_on_backend(backend, session, prompt, agent_name) do
    if backend == Shazam.Backend.ClaudeCode do
      execute_claude_query(session, prompt, agent_name)
    else
      result = backend.send_query(session, prompt)

      case result do
        {:ok, text, files} ->
          notify_agent_result(agent_name, "Completed")
          {:ok, text, files}
        {:error, _} = err ->
          err
      end
    end
  end

  # ClaudeCode-specific query with streaming events and broadcasting
  defp execute_claude_query(session, prompt, agent_name) do
    touched_files = :ets.new(:touched_files, [:set, :private])
    Process.put(:text_delta_buffer, "")

    stream = ClaudeCode.stream(session, prompt, include_partial_messages: true)

    stream =
      if agent_name do
        stream
        |> ClaudeCode.Stream.tap(fn message ->
          broadcast_backend_event(agent_name, message)
          collect_touched_files_claude(message, touched_files)
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

  defp execute_stream_on_backend(backend, session, name, prompt) do
    if backend == Shazam.Backend.ClaudeCode do
      execute_claude_stream(session, name, prompt)
    else
      execute_generic_stream(backend, session, name, prompt)
    end
  end

  defp execute_claude_stream(session, name, prompt) do
    IO.puts("\n--- [#{name}] ---")

    text =
      session
      |> ClaudeCode.stream(prompt)
      |> ClaudeCode.Stream.text_content()
      |> Enum.map(fn chunk ->
        IO.write(chunk)
        chunk
      end)
      |> Enum.join()

    IO.puts("\n--- [/#{name}] ---\n")
    {:ok, text}
  end

  defp execute_generic_stream(backend, session, name, prompt) do
    IO.puts("\n--- [#{name}] ---")

    {text, files} =
      backend.stream(session, prompt, [])
      |> Enum.reduce({"", []}, fn event, {text_acc, files_acc} ->
        case event do
          {:text_delta, chunk} ->
            IO.write(chunk)
            {text_acc <> chunk, files_acc}

          {:tool_use, tool, input} ->
            new_files = EventNormalizer.extract_touched_file({:tool_use, tool, input})
            {text_acc, files_acc ++ new_files}

          {:result_ok, result_text} ->
            {result_text, files_acc}

          _ ->
            {text_acc, files_acc}
        end
      end)

    IO.puts("\n--- [/#{name}] ---\n")
    {:ok, text, files}
  end

  # --- Fallback Logic ---

  defp maybe_fallback(error, reason, name, prompt, system_prompt, fallback_model, timeout) do
    fallback_backend = Registry.fallback()

    cond do
      # Try cross-backend fallback first
      fallback_backend != nil and rate_limit_or_quota_error?(reason) ->
        Logger.warning("[#{name}] Primary backend limit reached, trying #{fallback_backend.name()} fallback")
        notify_agent_result(name, "Primary backend limit reached. Trying #{fallback_backend.name()} fallback...")

        config = %{
          system_prompt: system_prompt,
          timeout: timeout,
          cwd: Application.get_env(:shazam, :workspace, nil),
          model: nil
        }
        session_opts = fallback_backend.build_session_opts(config)

        case execute_on_backend(fallback_backend, session_opts, false, name, prompt) do
          {:ok, _text, _files} = ok ->
            notify_agent_result(name, "Completed via #{fallback_backend.name()} fallback")
            ok
          {:error, _} ->
            maybe_codex_fallback(error, reason, name, prompt, system_prompt, fallback_model, timeout)
        end

      # Then try Codex fallback
      true ->
        maybe_codex_fallback(error, reason, name, prompt, system_prompt, fallback_model, timeout)
    end
  end

  defp maybe_codex_fallback(error, reason, name, prompt, system_prompt, fallback_model, timeout) do
    cond do
      !codex_fallback_enabled?() ->
        error

      is_nil_or_empty(fallback_model) ->
        error

      !rate_limit_or_quota_error?(reason) ->
        error

      true ->
        fallback_timeout = codex_fallback_timeout_ms(timeout)
        notify_agent_result(name, "Claude limit reached. Trying Codex fallback...")
        notify_agent_progress(name, "Codex fallback started (timeout: #{div(fallback_timeout, 60_000)} min)")

        Logger.warning("[#{name}] Claude limit/quota detected. Falling back to Codex model '#{fallback_model}'")

        case execute_codex_fallback(name, prompt, system_prompt, fallback_model, fallback_timeout) do
          {:ok, _text, _files} = ok ->
            notify_agent_result(name, "Completed via Codex fallback")
            ok
          {:error, fallback_reason} ->
            notify_agent_result(name, "Codex fallback failed")
            {:error, {:claude_error, reason, :codex_fallback_error, fallback_reason}}
        end
    end
  end

  defp execute_codex_fallback(name, prompt, system_prompt, model, timeout) do
    with {:ok, cli_bin} <- fetch_codex_cli_bin(),
         {:ok, text} <- run_codex_exec(name, cli_bin, prompt, system_prompt, model, timeout) do
      Logger.info("[#{name}] Codex fallback succeeded")
      {:ok, text, []}
    else
      {:error, reason} = err ->
        Logger.error("[#{name}] Codex fallback failed: #{inspect(reason, limit: 300)}")
        err
    end
  end

  defp run_codex_exec(agent_name, cli_bin, prompt, system_prompt, model, timeout) do
    workspace = Application.get_env(:shazam, :workspace, File.cwd!())
    combined_prompt = build_codex_prompt(prompt, system_prompt)

    with {:ok, out_path} <- make_codex_output_path() do
      args =
        [
          "exec",
          "--skip-git-repo-check",
          "--ephemeral",
          "--full-auto",
          "--sandbox",
          "workspace-write",
          "--color",
          "never",
          "--output-last-message",
          out_path
        ]
        |> maybe_add_cli_arg(model)
        |> maybe_add_cli_cwd(workspace)
        |> Kernel.++([combined_prompt])

      cmd_opts = [stderr_to_stdout: true, cd: workspace]

      result =
        try do
          case run_system_cmd_with_progress(agent_name, cli_bin, args, cmd_opts, timeout) do
            {:ok, {output, status}} ->
              parse_codex_exec_result(status, output, out_path)
            {:error, :timeout} ->
              {:error, {:codex_exec_timeout, timeout}}
          end
        rescue
          e -> {:error, {:codex_exec_failed, Exception.message(e)}}
        after
          File.rm(out_path)
        end

      result
    end
  end

  defp parse_codex_exec_result(0, _output, out_path) do
    case File.read(out_path) do
      {:ok, text} when is_binary(text) and text != "" -> {:ok, String.trim(text)}
      {:ok, _} -> {:error, :empty_codex_output}
      {:error, reason} -> {:error, {:codex_output_read_failed, reason}}
    end
  end
  defp parse_codex_exec_result(status, output, _out_path),
    do: {:error, {:codex_exec_exit_status, status, String.slice(output, 0, 2_000)}}

  defp run_system_cmd_with_progress(agent_name, bin, args, opts, timeout) do
    task = Task.async(fn -> System.cmd(bin, args, opts) end)
    started_at = System.monotonic_time(:millisecond)
    tick_ms = codex_progress_interval_ms()
    await_with_progress(task, agent_name, started_at, timeout, tick_ms)
  end

  defp await_with_progress(task, _agent_name, _started_at, timeout, _tick_ms) when timeout <= 0 do
    Task.shutdown(task, :brutal_kill)
    {:error, :timeout}
  end

  defp await_with_progress(task, agent_name, started_at, timeout, tick_ms) do
    case Task.yield(task, tick_ms) do
      {:ok, result} ->
        {:ok, result}
      nil ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        if elapsed_ms >= timeout do
          Task.shutdown(task, :brutal_kill)
          {:error, :timeout}
        else
          elapsed_s = div(elapsed_ms, 1_000)
          remaining_s = max(div(timeout - elapsed_ms, 1_000), 0)
          notify_agent_progress(agent_name, "Codex fallback in progress... #{elapsed_s}s elapsed, #{remaining_s}s remaining")
          await_with_progress(task, agent_name, started_at, timeout, tick_ms)
        end
    end
  end

  # --- Broadcasting ---

  defp broadcast_backend_event(agent_name, message) do
    backend = Registry.current()

    case backend.normalize_event(message) do
      {:text_delta, text} ->
        buffer = (Process.get(:text_delta_buffer) || "") <> (text || "")
        if String.length(buffer) >= @broadcast_batch_chars do
          Shazam.API.EventBus.broadcast(%{
            event: "agent_output",
            agent: agent_name,
            type: "text_delta",
            content: buffer
          })
          Process.put(:text_delta_buffer, "")
        else
          Process.put(:text_delta_buffer, buffer)
        end

      {:assistant, sub_events} ->
        flush_text_buffer(agent_name)
        Enum.each(sub_events, fn
          {:tool_use, tool_name, input} ->
            Shazam.API.EventBus.broadcast(%{
              event: "agent_output",
              agent: agent_name,
              type: "tool_use",
              content: "#{tool_name}: #{inspect(input, limit: 200)}"
            })
          {:text, text} ->
            Shazam.API.EventBus.broadcast(%{
              event: "agent_output",
              agent: agent_name,
              type: "text",
              content: text
            })
          _ -> :ok
        end)

      {:result_ok, _} ->
        notify_agent_result(agent_name, "Completed")

      {:result_error, result} ->
        notify_agent_result(agent_name, "Failed: #{format_result_error(result)}")

      :ignore ->
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp flush_text_buffer(agent_name) do
    buffer = Process.get(:text_delta_buffer) || ""
    if buffer != "" do
      Shazam.API.EventBus.broadcast(%{
        event: "agent_output",
        agent: agent_name,
        type: "text_delta",
        content: buffer
      })
      Process.put(:text_delta_buffer, "")
    end
  end

  defp collect_touched_files_claude(message, table) do
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

  # --- Notifications ---

  defp notify_agent_result(agent_name, content) do
    Shazam.API.EventBus.broadcast(%{
      event: "agent_output",
      agent: agent_name,
      type: "result",
      content: content
    })
  end

  defp notify_agent_progress(agent_name, content) do
    Shazam.API.EventBus.broadcast(%{
      event: "agent_output",
      agent: agent_name,
      type: "text",
      content: content
    })
  end

  defp format_result_error(result) when is_binary(result), do: String.slice(result, 0, 300)
  defp format_result_error(result), do: inspect(result, limit: 200)

  # --- Helpers ---

  defp make_codex_output_path do
    base = System.tmp_dir!()
    file = "shazam_codex_output_#{System.unique_integer([:positive])}.txt"
    {:ok, Path.join(base, file)}
  end

  defp build_codex_prompt(prompt, system_prompt) do
    """
    System instructions:
    #{system_prompt}

    Task:
    #{prompt}
    """
  end

  defp maybe_add_cli_arg(args, model) do
    if is_nil_or_empty(model), do: args, else: args ++ ["--model", model]
  end

  defp maybe_add_cli_cwd(args, cwd) do
    if is_nil_or_empty(cwd), do: args, else: args ++ ["--cd", cwd]
  end

  defp fetch_codex_cli_bin do
    configured = Application.get_env(:shazam, :codex_cli_bin, "codex")
    case System.find_executable(configured) do
      nil -> {:error, {:codex_cli_not_found, configured}}
      path -> {:ok, path}
    end
  end

  defp resolve_fallback_model(agent) do
    configured =
      agent[:fallback_model] ||
        Application.get_env(:shazam, :codex_fallback_model, @default_codex_fallback_model)
    if is_nil_or_empty(configured), do: nil, else: configured
  end

  defp codex_fallback_enabled? do
    Application.get_env(:shazam, :codex_fallback_enabled, true)
  end

  defp codex_fallback_timeout_ms(default_timeout) do
    Application.get_env(:shazam, :codex_fallback_timeout_ms, default_timeout || @default_codex_fallback_timeout_ms)
  end

  defp codex_progress_interval_ms do
    Application.get_env(:shazam, :codex_progress_interval_ms, @default_codex_progress_interval_ms)
  end

  defp rate_limit_or_quota_error?(reason) do
    patterns = [
      "429", "rate limit", "ratelimit", "rate_limit", "quota",
      "insufficient_quota", "too many requests", "resource exhausted",
      "credit balance is too low", "exceeded your current quota",
      "hit your limit", "you've hit your limit", "limit reached",
      "usage limit", "resets "
    ]

    reason
    |> collect_error_texts()
    |> Enum.map(&String.downcase/1)
    |> Enum.any?(fn text ->
      Enum.any?(patterns, &String.contains?(text, &1))
    end)
  end

  defp is_nil_or_empty(nil), do: true
  defp is_nil_or_empty(""), do: true
  defp is_nil_or_empty(_), do: false

  defp collect_error_texts(reason) do
    [inspect(reason, limit: 500)] ++ do_collect_error_texts(reason)
  end

  defp do_collect_error_texts(reason) when is_binary(reason), do: [reason]
  defp do_collect_error_texts(reason) when is_map(reason) do
    [
      Map.get(reason, :result), Map.get(reason, "result"),
      Map.get(reason, :message), Map.get(reason, "message"),
      Map.get(reason, :error), Map.get(reason, "error")
    ]
    |> Enum.flat_map(&do_collect_error_texts/1)
  end
  defp do_collect_error_texts(reason) when is_tuple(reason) do
    reason |> Tuple.to_list() |> Enum.flat_map(&do_collect_error_texts/1)
  end
  defp do_collect_error_texts(reason) when is_list(reason) do
    Enum.flat_map(reason, &do_collect_error_texts/1)
  end
  defp do_collect_error_texts(_), do: []

  defp resolve_prompt(agent, nil), do: agent[:prompt]
  defp resolve_prompt(agent, prev_output) do
    case agent[:prompt] do
      fun when is_function(fun, 1) -> fun.(prev_output)
      prompt -> "#{prompt}\n\nPrevious context:\n#{prev_output}"
    end
  end

  defp aggregate_results(agents, results) do
    agents
    |> Enum.zip(results)
    |> Enum.map(fn {agent, result} ->
      case result do
        {:ok, text, files} ->
          %{name: agent[:name] || "unnamed", result: {:ok, text}, touched_files: files}
        other ->
          %{name: agent[:name] || "unnamed", result: other, touched_files: []}
      end
    end)
  end
end
