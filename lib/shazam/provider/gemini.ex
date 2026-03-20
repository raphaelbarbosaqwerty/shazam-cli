defmodule Shazam.Provider.Gemini do
  @moduledoc """
  Provider implementation for Google Gemini CLI.
  Stateless — each execution spawns a new CLI process.
  """

  @behaviour Shazam.Provider

  require Logger

  @default_timeout 600_000

  @impl true
  def name, do: "gemini"

  @impl true
  def supports_sessions?, do: false

  @impl true
  def available? do
    System.find_executable("gemini") != nil
  end

  @impl true
  def start_session(_opts), do: {:ok, :stateless}

  @impl true
  def stop_session(_session), do: :ok

  @impl true
  def execute(_session, prompt, opts \\ []) do
    agent_name = Keyword.get(opts, :agent_name, "gemini")
    system_prompt = Keyword.get(opts, :system_prompt, "")
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    workspace = Keyword.get(opts, :cwd, File.cwd!())

    case System.find_executable("gemini") do
      nil ->
        {:error, {:gemini_cli_not_found, "gemini"}}

      cli_bin ->
        combined_prompt = if system_prompt != "" do
          "#{system_prompt}\n\n#{prompt}"
        else
          prompt
        end

        notify(agent_name, "Starting Gemini execution...")

        task = Task.async(fn ->
          System.cmd(cli_bin, ["--prompt", combined_prompt],
            stderr_to_stdout: true, cd: workspace)
        end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, 0}} ->
            notify(agent_name, "Completed via Gemini")
            {:ok, String.trim(output), []}

          {:ok, {output, status}} ->
            {:error, {:gemini_exit_status, status, String.slice(output, 0, 2000)}}

          nil ->
            {:error, {:gemini_timeout, timeout}}
        end
    end
  end

  defp notify(agent_name, content) do
    Shazam.API.EventBus.broadcast(%{
      event: "agent_output", agent: agent_name, type: "text", content: content
    })
  rescue
    _ -> :ok
  end
end
