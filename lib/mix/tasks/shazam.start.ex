defmodule Mix.Tasks.Shazam.Start do
  @moduledoc "Start Shazam from shazam.yaml config."
  @shortdoc "Boot server and create company from shazam.yaml"

  use Mix.Task
  require Logger

  alias Shazam.CLI.{Formatter, YamlParser}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args,
      switches: [port: :integer, no_resume: :boolean, file: :string],
      aliases: [p: :port, f: :file]
    )

    # Set port before app starts
    if opts[:port], do: Application.put_env(:shazam, :port, opts[:port])

    yaml_file = opts[:file] || default_yaml()

    # Parse YAML first (before starting app)
    config = case YamlParser.parse(yaml_file) do
      {:ok, config} -> config
      {:error, reason} ->
        Formatter.error(reason)
        Formatter.dim("Run 'mix shazam.init' to create a shazam.yaml")
        System.halt(1)
    end

    Formatter.banner()

    # Start OTP app
    Mix.Task.run("app.start")

    port = Application.get_env(:shazam, :port, 4040)
    Formatter.info("Server running on port #{port}")

    # Set workspace
    workspace = config[:workspace] || File.cwd!()
    Application.put_env(:shazam, :workspace, workspace)
    Shazam.Store.save("workspace", %{"path" => workspace})
    Formatter.info("Workspace: #{workspace}")

    # Check if company already running
    company_name = config.name
    already_running = Shazam.RalphLoop.exists?(company_name)

    if already_running do
      Formatter.warning("Company '#{company_name}' already running — skipping creation")
    else
      # Start company
      company_config = %{
        name: company_name,
        mission: config.mission,
        agents: config.agents,
        domain_config: config[:domain_config] || %{}
      }

      case Shazam.start_company(company_config) do
        {:ok, _pid} ->
          Formatter.success("Company '#{company_name}' started — #{length(config.agents)} agent(s)")
        {:error, {:already_started, _}} ->
          Formatter.warning("Company '#{company_name}' already exists")
        {:error, reason} ->
          Formatter.error("Failed to start company: #{inspect(reason)}")
          System.halt(1)
      end
    end

    # Auto-resume RalphLoop unless --no-resume
    unless opts[:no_resume] do
      case Shazam.RalphLoop.resume(company_name) do
        {:ok, _} -> Formatter.success("RalphLoop resumed — agents are autonomous")
        _ -> Formatter.warning("RalphLoop not started yet")
      end
    end

    # Print summary
    Formatter.divider()
    print_agents(config.agents)
    Formatter.divider()
    Formatter.dim("Press Ctrl+C to stop")
    IO.puts("")

    # Keep alive
    Process.sleep(:infinity)
  end

  defp default_yaml do
    if File.exists?(".shazam/shazam.yaml"), do: ".shazam/shazam.yaml", else: "shazam.yaml"
  end

  defp print_agents(agents) do
    headers = ["Agent", "Role", "Supervisor", "Budget", "Model"]
    rows = Enum.map(agents, fn a ->
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
