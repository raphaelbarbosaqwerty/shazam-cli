defmodule Shazam.CLI.Commands.Start do
  @moduledoc """
  Implements `shazam start` — boots the OTP application, creates the
  company from `shazam.yaml`, configures RalphLoop, and blocks.
  """

  alias Shazam.CLI.{Formatter, Shared}
  require Logger

  @port 4040

  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [port: :integer, no_resume: :boolean, file: :string],
        aliases: [p: :port, f: :file]
      )

    yaml_file = opts[:file] || Shared.default_yaml()

    config =
      case Shazam.CLI.YamlParser.parse(yaml_file) do
        {:ok, config} ->
          config

        {:error, reason} ->
          Formatter.error(reason)
          Formatter.dim("Run 'shazam init' to create a shazam.yaml")
          System.halt(1)
      end

    Formatter.banner_static()

    port = opts[:port] || @port
    Application.put_env(:shazam, :port, port)

    # Boot OTP app — suppress noisy NIF/SQLite warnings
    :logger.set_primary_config(:level, :error)
    Logger.configure(level: :error)
    Shared.boot_app()
    Logger.configure(level: :info)
    :logger.set_primary_config(:level, :info)

    Formatter.info("Server running on port #{port}")

    # Set workspace
    workspace = config[:workspace] || File.cwd!()
    Application.put_env(:shazam, :workspace, workspace)
    Shazam.Store.save("workspace", %{"path" => workspace})
    Formatter.info("Workspace: #{workspace}")

    # Set tech_stack if present
    if config[:tech_stack], do: Application.put_env(:shazam, :tech_stack, config.tech_stack)

    company_name = config.name

    unless Shazam.RalphLoop.exists?(company_name) do
      company_config = %{
        name: company_name,
        mission: config.mission,
        agents: config.agents,
        domain_config: config[:domain_config] || %{}
      }

      case Shazam.start_company(company_config) do
        {:ok, _} ->
          Formatter.success("Company '#{company_name}' started — #{length(config.agents)} agent(s)")

        {:error, {:already_started, _}} ->
          Formatter.warning("Company '#{company_name}' already exists")

        {:error, reason} ->
          Formatter.error("Failed: #{inspect(reason)}")
          System.halt(1)
      end
    else
      Formatter.warning("Company '#{company_name}' already running")
    end

    # Apply ralph_config from YAML if present
    if config[:ralph_config] do
      rc = config.ralph_config

      try do
        if rc[:auto_approve], do: Shazam.RalphLoop.set_auto_approve(company_name, true)
        Shazam.RalphLoop.set_config(company_name, "max_concurrent", rc[:max_concurrent] || 4)
        Shazam.RalphLoop.set_config(company_name, "poll_interval", rc[:poll_interval] || 5000)
        Shazam.RalphLoop.set_config(company_name, "module_lock", Map.get(rc, :module_lock, true))
        Shazam.RalphLoop.set_config(company_name, "peer_reassign", Map.get(rc, :peer_reassign, true))
        Shazam.RalphLoop.set_config(company_name, "auto_retry", rc[:auto_retry] || false)
        Shazam.RalphLoop.set_config(company_name, "max_retries", rc[:max_retries] || 2)
      rescue
        _ -> :ok
      end
    end

    unless opts[:no_resume] do
      case Shazam.RalphLoop.resume(company_name) do
        {:ok, _} -> Formatter.success("RalphLoop active — agents working")
        _ -> :ok
      end
    end

    Formatter.divider()
    print_agents_table(config.agents)
    Formatter.divider()
    Formatter.dim("Press Ctrl+C to stop")
    IO.puts("")

    Process.sleep(:infinity)
  end

  # ── private ───────────────────────────────────────────────

  defp print_agents_table(agents) do
    headers = ["Agent", "Role", "Supervisor", "Budget", "Model"]

    rows =
      Enum.map(agents, fn a ->
        [
          a.name,
          a.role,
          a[:supervisor] || "—",
          "#{div(a[:budget] || 100_000, 1000)}k",
          a[:model] || "default"
        ]
      end)

    Formatter.table(headers, rows)
  end
end
