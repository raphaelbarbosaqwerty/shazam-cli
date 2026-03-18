defmodule Shazam.CLI.YamlParser do
  @moduledoc "Parses shazam.yaml into company config."

  @doc "Reads and parses a shazam.yaml file."
  def parse(path \\ nil) do
    path = path || default_yaml()
    case YamlElixir.read_from_file(path) do
      {:ok, data} -> transform(data)
      {:error, reason} -> {:error, "Failed to parse #{path}: #{inspect(reason)}"}
    end
  end

  @doc "Transforms parsed YAML map into Company.start/1 config."
  def transform(data) when is_map(data) do
    company = data["company"] || %{}
    name = company["name"]
    mission = company["mission"]

    domains = data["domains"] || %{}
    agents_map = data["agents"] || %{}

    agents = build_agents(agents_map, domains)

    # Validate structural requirements
    with :ok <- validate_company_section(company),
         :ok <- validate_agents_section(agents_map),
         :ok <- validate_agents(agents, agents_map) do
      domain_config = build_domain_config(domains)
      ralph_config = build_ralph_config(data["config"] || %{})

      tech_stack = build_tech_stack(data["tech_stack"])

      # backend: under company: (preferred) or root-level backend: (common mistake)
      backend =
        parse_backend(company["backend"]) ||
          parse_backend(data["backend"])

      fallback_backend = parse_backend(company["fallback_backend"])

      cursor_cli_bin =
        case company["cursor_cli_bin"] do
          b when is_binary(b) ->
            t = String.trim(b)
            if t != "", do: t, else: nil

          _ ->
            nil
        end

      {:ok, %{
        name: name,
        mission: mission,
        agents: agents,
        domain_config: domain_config,
        workspace: company["workspace"],
        ralph_config: ralph_config,
        tech_stack: tech_stack,
        backend: backend,
        fallback_backend: fallback_backend,
        cursor_cli_bin: cursor_cli_bin
      }}
    else
      {:error, _} = err -> err
    end
  end

  def transform(_), do: {:error, "Invalid YAML format — expected a map"}

  defp build_agents(agents_map, domains) do
    # First pass: build supervisor map from "supervises" fields
    supervisor_map = agents_map
      |> Enum.reduce(%{}, fn {agent_name, config}, acc ->
        supervises = config["supervises"] || []
        Enum.reduce(supervises, acc, fn sub, a -> Map.put(a, sub, agent_name) end)
      end)

    agents_map
    |> Enum.map(fn {agent_name, config} ->
      # Explicit supervisor takes priority, then derived from "supervises"
      supervisor = config["supervisor"] || Map.get(supervisor_map, agent_name)
      domain = config["domain"]
      domain_paths = if domain, do: get_in(domains, [domain, "paths"]) || [], else: []

      %{
        name: agent_name,
        role: config["role"] || "Agent",
        supervisor: supervisor,
        domain: domain,
        budget: config["budget"] || 100_000,
        heartbeat_interval: config["heartbeat_interval"] || 60_000,
        model: config["model"],
        fallback_model: config["fallback_model"],
        tools: config["tools"] || default_tools(config["role"]),
        skills: config["skills"] || [],
        modules: build_modules(domain, domain_paths),
        system_prompt: config["system_prompt"]
      }
    end)
  end

  defp build_modules(nil, _), do: []
  defp build_modules(domain, paths) do
    [%{"name" => domain, "paths" => paths}]
  end

  defp build_domain_config(domains) do
    domains
    |> Enum.reduce(%{}, fn {name, config}, acc ->
      Map.put(acc, name, %{"allowed_paths" => config["paths"] || []})
    end)
  end

  defp validate_company_section(company) do
    cond do
      !is_map(company) ->
        {:error, "company section must be a map with name and mission keys"}
      !is_binary(company["name"]) or String.trim(company["name"]) == "" ->
        {:error, "company.name is required and must be a non-empty string"}
      !is_binary(company["mission"]) or String.trim(company["mission"]) == "" ->
        {:error, "company.mission is required and must be a non-empty string"}
      true -> :ok
    end
  end

  defp validate_agents_section(agents_map) do
    cond do
      !is_map(agents_map) ->
        {:error, "agents section must be a map of agent_name: {role:, ...}"}
      map_size(agents_map) == 0 ->
        {:error, "at least one agent is required in the agents section"}
      true ->
        errors = Enum.flat_map(agents_map, fn {name, config} ->
          cond do
            !is_map(config) ->
              ["Agent '#{name}' must have a configuration map (role, budget, etc.)"]
            !is_binary(config["role"]) ->
              ["Agent '#{name}' is missing the required 'role' field"]
            true ->
              []
          end
        end)
        if errors == [], do: :ok, else: {:error, Enum.join(errors, "\n")}
    end
  end

  defp validate_agents(agents, agents_map) do
    agent_names = MapSet.new(Map.keys(agents_map))

    errors = agents
      |> Enum.flat_map(fn agent ->
        cond do
          agent.supervisor && !MapSet.member?(agent_names, agent.supervisor) ->
            ["Agent '#{agent.name}' references unknown supervisor '#{agent.supervisor}'"]
          true ->
            []
        end
      end)

    if errors == [], do: :ok, else: {:error, Enum.join(errors, "\n")}
  end

  defp build_tech_stack(nil), do: nil
  defp build_tech_stack(stack) when is_map(stack), do: stack
  defp build_tech_stack(_), do: nil

  defp build_ralph_config(config) when is_map(config) do
    %{
      auto_approve: config["auto_approve"] || false,
      auto_retry: config["auto_retry"] || false,
      max_concurrent: config["max_concurrent"] || 4,
      max_retries: config["max_retries"] || 2,
      poll_interval: config["poll_interval"] || 5_000,
      module_lock: Map.get(config, "module_lock", true),
      peer_reassign: Map.get(config, "peer_reassign", true)
    }
  end
  defp build_ralph_config(_), do: build_ralph_config(%{})

  defp default_tools(role) when is_binary(role) do
    role_lower = String.downcase(role)
    cond do
      String.contains?(role_lower, "manager") or String.contains?(role_lower, "pm") ->
        ["Read", "Grep", "Glob", "WebSearch"]
      String.contains?(role_lower, "developer") or String.contains?(role_lower, "dev") ->
        ["Read", "Edit", "Write", "Bash", "Grep", "Glob"]
      String.contains?(role_lower, "qa") or String.contains?(role_lower, "test") ->
        ["Read", "Bash", "Grep", "Glob"]
      String.contains?(role_lower, "design") ->
        ["Read", "WebSearch", "WebFetch"]
      true ->
        ["Read", "Grep", "Glob"]
    end
  end

  defp default_tools(_), do: ["Read", "Grep", "Glob"]

  @doc "Generates a YAML string from a config map."
  def to_yaml(config) do
    backend_line = if config[:backend] && config[:backend] != :claude_code do
      "\n  backend: #{config.backend}"
    else
      ""
    end

    fallback_line = if config[:fallback_backend] do
      "\n  fallback_backend: #{config.fallback_backend}"
    else
      ""
    end

    cursor_bin_line =
      if config[:cursor_cli_bin] && config[:cursor_cli_bin] != "" do
        "\n  cursor_cli_bin: #{quote_str(config.cursor_cli_bin)}"
      else
        ""
      end

    company = "company:\n  name: #{quote_str(config.name)}\n  mission: #{quote_str(config.mission)}#{backend_line}#{fallback_line}#{cursor_bin_line}\n"

    domains = if config[:domains] && map_size(config.domains) > 0 do
      domain_lines = config.domains
        |> Enum.map(fn {name, d} ->
          paths = (d["paths"] || d[:paths] || []) |> Enum.map(&"      - #{quote_str(&1)}") |> Enum.join("\n")
          desc = d["description"] || d[:description] || name
          "  #{name}:\n    description: #{quote_str(desc)}\n    paths:\n#{paths}"
        end)
        |> Enum.join("\n")
      "\ndomains:\n#{domain_lines}\n"
    else
      ""
    end

    agents = if config[:agents] && length(config.agents) > 0 do
      agent_lines = config.agents
        |> Enum.map(fn a ->
          lines = ["  #{a.name}:", "    role: #{quote_str(a.role)}"]
          lines = if a[:supervisor], do: lines ++ ["    supervisor: #{a.supervisor}"], else: lines
          lines = if a[:domain], do: lines ++ ["    domain: #{a.domain}"], else: lines
          lines = if a[:model], do: lines ++ ["    model: #{a.model}"], else: lines
          lines = lines ++ ["    budget: #{a[:budget] || 100_000}"]
          lines = if a[:tools] && a[:tools] != [] do
            tools = a.tools |> Enum.map(&"      - #{&1}") |> Enum.join("\n")
            lines ++ ["    tools:\n#{tools}"]
          else
            lines
          end
          Enum.join(lines, "\n")
        end)
        |> Enum.join("\n\n")
      "\nagents:\n#{agent_lines}\n"
    else
      ""
    end

    config_section = if config[:ralph_config] do
      rc = config.ralph_config
      """

      # Debug & runtime settings (same as Flutter debug panel)
      config:
        auto_approve: #{rc[:auto_approve] || false}
        auto_retry: #{rc[:auto_retry] || false}
        max_concurrent: #{rc[:max_concurrent] || 4}
        max_retries: #{rc[:max_retries] || 2}
        poll_interval: #{rc[:poll_interval] || 5000}
        module_lock: #{Map.get(rc, :module_lock, true)}
        peer_reassign: #{Map.get(rc, :peer_reassign, true)}
      """
    else
      """

      # Debug & runtime settings (same as Flutter debug panel)
      config:
        auto_approve: false       # Skip human approval for PM subtasks
        auto_retry: false         # Auto-retry failed tasks with backoff
        max_concurrent: 4         # Max agents working simultaneously (1-10)
        max_retries: 2            # Default retry attempts per failed task
        poll_interval: 5000       # Task polling interval in ms
        module_lock: true         # Prevent agents from editing modules owned by other hierarchies
        peer_reassign: true       # Reassign tasks to idle peers when assigned agent is busy
      """
    end

    tech_stack_section = if config[:tech_stack] && map_size(config.tech_stack) > 0 do
      lines = config.tech_stack
        |> Enum.map(fn {key, value} ->
          if is_binary(value) and String.contains?(value, "\n") do
            "  #{key}: |\n#{value |> String.split("\n") |> Enum.map_join("\n", &"    #{&1}")}"
          else
            "  #{key}: #{quote_str(to_string(value))}"
          end
        end)
        |> Enum.join("\n")
      "\n# Tech stack — shared with all agents as project context\ntech_stack:\n#{lines}\n"
    else
      "\n# Tech stack — shared with all agents as project context\n# tech_stack:\n#   language: Elixir\n#   framework: Phoenix\n#   database: PostgreSQL\n#   frontend: Flutter\n#   notes: |\n#     Additional context about the project stack\n"
    end

    company <> domains <> agents <> config_section <> tech_stack_section
  end

  defp quote_str(s) when is_binary(s) do
    if String.contains?(s, [":", "#", "'", "\"", "\n"]) do
      "\"#{String.replace(s, "\"", "\\\"")}\""
    else
      s
    end
  end
  defp quote_str(s), do: to_string(s)

  @valid_backends ~w(claude_code cursor_cli)
  @backend_aliases %{"cursor" => :cursor_cli}

  defp parse_backend(nil), do: nil
  defp parse_backend(str) when is_binary(str) do
    normalized = str |> String.downcase() |> String.replace("-", "_") |> String.replace(" ", "_")

    cond do
      normalized in @valid_backends ->
        String.to_atom(normalized)

      Map.has_key?(@backend_aliases, normalized) ->
        Map.fetch!(@backend_aliases, normalized)

      true ->
        nil
    end
  end
  defp parse_backend(_), do: nil

  defp default_yaml do
    if File.exists?(".shazam/shazam.yaml"), do: ".shazam/shazam.yaml", else: "shazam.yaml"
  end
end
