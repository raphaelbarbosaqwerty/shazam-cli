defmodule Shazam.Provider.Codex do
  @moduledoc """
  Provider implementation for OpenAI Codex CLI.
  Stateless — each execution spawns a new CLI process.
  """

  @behaviour Shazam.Provider

  require Logger

  @default_timeout 1_800_000

  @impl true
  def name, do: "codex"

  @impl true
  def supports_sessions?, do: false

  @impl true
  def available? do
    System.find_executable("codex") != nil
  end

  @impl true
  def start_session(_opts) do
    # Codex is stateless — no persistent sessions
    {:ok, :stateless}
  end

  @impl true
  def stop_session(_session), do: :ok

  @impl true
  def execute(_session, prompt, opts \\ []) do
    agent_name = Keyword.get(opts, :agent_name, "codex")
    system_prompt = Keyword.get(opts, :system_prompt, "")
    model = Keyword.get(opts, :model, "gpt-5-codex")
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    workspace = Keyword.get(opts, :cwd, File.cwd!())

    case System.find_executable("codex") do
      nil ->
        {:error, {:codex_cli_not_found, "codex"}}

      cli_bin ->
        combined_prompt = """
        System instructions:
        #{system_prompt}

        Task:
        #{prompt}
        """

        out_path = Path.join(System.tmp_dir!(), "shazam_codex_#{System.unique_integer([:positive])}.txt")

        args =
          ["exec", "--skip-git-repo-check", "--ephemeral", "--full-auto",
           "--sandbox", "workspace-write", "--color", "never",
           "--output-last-message", out_path]
          |> add_if(model, ["--model", model])
          |> add_if(workspace, ["--cd", workspace])
          |> Kernel.++([combined_prompt])

        notify(agent_name, "Starting Codex execution...")

        try do
          task = Task.async(fn -> System.cmd(cli_bin, args, stderr_to_stdout: true, cd: workspace) end)

          case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
            {:ok, {_output, 0}} ->
              case File.read(out_path) do
                {:ok, text} when text != "" ->
                  notify(agent_name, "Completed via Codex")
                  {:ok, String.trim(text), []}
                _ ->
                  {:error, :empty_codex_output}
              end

            {:ok, {output, status}} ->
              {:error, {:codex_exit_status, status, String.slice(output, 0, 2000)}}

            nil ->
              {:error, {:codex_timeout, timeout}}
          end
        after
          File.rm(out_path)
        end
    end
  end

  defp add_if(args, nil, _extra), do: args
  defp add_if(args, "", _extra), do: args
  defp add_if(args, _val, extra), do: args ++ extra

  defp notify(agent_name, content) do
    Shazam.API.EventBus.broadcast(%{
      event: "agent_output", agent: agent_name, type: "text", content: content
    })
  rescue
    _ -> :ok
  end
end
