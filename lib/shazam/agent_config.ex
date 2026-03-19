defmodule Shazam.AgentConfig do
  @moduledoc "Read and write agent configuration from .shazam/agents/*.md files."

  @agents_dir ".shazam/agents"

  @doc "Returns the agents config directory."
  def agents_dir do
    workspace = Application.get_env(:shazam, :workspace, File.cwd!())
    Path.join(workspace, @agents_dir)
  end

  @doc "Ensure the agents directory exists."
  def ensure_dir do
    dir = agents_dir()
    File.mkdir_p!(dir)
    dir
  end

  @doc "Write an agent config from a preset to a .md file."
  def write_preset(agent_name, preset_id) do
    case Shazam.AgentPresets.get(preset_id) do
      nil -> {:error, :preset_not_found}
      preset ->
        dir = ensure_dir()
        path = Path.join(dir, "#{agent_name}.md")
        content = render_agent_md(agent_name, preset.defaults)
        File.write!(path, content)
        {:ok, path}
    end
  end

  @doc "Write an agent config from a map to a .md file."
  def write_agent(agent_name, config) do
    dir = ensure_dir()
    path = Path.join(dir, "#{agent_name}.md")
    content = render_agent_md(agent_name, config)
    File.write!(path, content)
    {:ok, path}
  end

  @doc "Read an agent config from its .md file. Returns the system prompt and any overrides."
  def read_agent(agent_name) do
    dir = agents_dir()
    path = Path.join(dir, "#{agent_name}.md")

    case File.read(path) do
      {:ok, content} -> parse_agent_md(content)
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Read an agent config from an explicit file path."
  def read_agent_from_path(path) do
    case File.read(path) do
      {:ok, content} -> parse_agent_md(content)
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Check if an agent .md file exists."
  def exists?(agent_name) do
    dir = agents_dir()
    File.exists?(Path.join(dir, "#{agent_name}.md"))
  end

  @doc "List all agent .md files."
  def list_agents do
    dir = agents_dir()
    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.map(fn f -> String.trim_trailing(f, ".md") end)
    else
      []
    end
  end

  @doc "Write all preset agents for a given list of agent configs (from shazam init)."
  def init_agents(agents) do
    ensure_dir()
    Enum.each(agents, fn agent ->
      name = agent[:name] || agent.name
      role = agent[:role] || agent.role || "Agent"

      # Try to find a matching preset by role
      preset_id = find_preset_for_role(role)

      if preset_id do
        case Shazam.AgentPresets.get(preset_id) do
          nil -> write_agent(name, %{role: role, system_prompt: "You are a #{role}."})
          preset ->
            # Merge agent-specific overrides with preset defaults
            config = Map.merge(preset.defaults, %{
              role: role,
              model: agent[:model] || preset.defaults.model,
              budget: agent[:budget] || preset.defaults.budget,
              tools: agent[:tools] || preset.defaults.tools
            })
            write_agent(name, config)
        end
      else
        write_agent(name, %{role: role, system_prompt: "You are a #{role}. Be direct and objective."})
      end
    end)
  end

  # ── Private ──────────────────────────────────────────────

  defp render_agent_md(_name, config) do
    role = config[:role] || Map.get(config, :role, "Agent")
    model = config[:model] || Map.get(config, :model, nil)
    budget = config[:budget] || Map.get(config, :budget, 100_000)
    tools = config[:tools] || Map.get(config, :tools, [])
    system_prompt = config[:system_prompt] || Map.get(config, :system_prompt, "You are a #{role}.")

    tools_str = if is_list(tools) and tools != [] do
      Enum.join(tools, ", ")
    else
      ""
    end

    frontmatter = [
      "---",
      "role: #{role}",
      if(model, do: "model: #{model}", else: nil),
      "budget: #{budget}",
      if(tools_str != "", do: "tools: [#{tools_str}]", else: nil),
      "---"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")

    frontmatter <> "\n\n" <> String.trim(to_string(system_prompt)) <> "\n"
  end

  defp parse_agent_md(content) do
    case Regex.run(~r/\A---\n(.*?)\n---\n?(.*)/s, content) do
      [_, frontmatter, body] ->
        meta = parse_frontmatter(frontmatter)
        system_prompt = String.trim(body)

        {:ok, %{
          role: meta["role"],
          model: meta["model"],
          budget: parse_int(meta["budget"]),
          tools: parse_tools(meta["tools"]),
          system_prompt: system_prompt
        }}
      _ ->
        # No frontmatter — treat entire file as system prompt
        {:ok, %{system_prompt: String.trim(content)}}
    end
  end

  defp parse_frontmatter(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ": ", parts: 2) do
        [key, value] ->
          Map.put(acc, String.trim(key), String.trim(value))
        _ -> acc
      end
    end)
  end

  defp parse_int(nil), do: nil
  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end
  defp parse_int(n) when is_integer(n), do: n

  defp parse_tools(nil), do: nil
  defp parse_tools(str) when is_binary(str) do
    str
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp find_preset_for_role(role) do
    role_lower = String.downcase(role)
    cond do
      String.contains?(role_lower, "project manager") or role_lower == "pm" -> "pm"
      String.contains?(role_lower, "senior dev") -> "senior_dev"
      String.contains?(role_lower, "junior dev") -> "junior_dev"
      String.contains?(role_lower, "qa") or String.contains?(role_lower, "test") -> "qa"
      String.contains?(role_lower, "design") -> "designer"
      String.contains?(role_lower, "research") -> "researcher"
      String.contains?(role_lower, "devops") -> "devops"
      String.contains?(role_lower, "writer") -> "writer"
      String.contains?(role_lower, "market") -> "market_analyst"
      String.contains?(role_lower, "competitor") -> "competitor_analyst"
      String.contains?(role_lower, "review") -> "pr_reviewer"
      true -> nil
    end
  end
end
