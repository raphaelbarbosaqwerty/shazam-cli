defmodule Shazam.ProjectDetector do
  @moduledoc """
  Analyzes a project directory and returns detected tech stack, frameworks,
  domains, and suggested agent configuration.

  Pure utility module — no side effects, just reads files and returns a map.
  """

  @doc """
  Detects the tech stack, domains, and suggests agents for the given project path.

  Returns a map with keys: language, framework, database, styling, testing,
  package_manager, monorepo, domains, suggested_agents, tech_stack.
  """
  def detect(path) do
    detections = %{
      language: nil,
      framework: nil,
      database: nil,
      styling: nil,
      testing: nil,
      package_manager: nil,
      monorepo: false,
      ci_cd: false
    }

    detections =
      detections
      |> detect_node(path)
      |> detect_elixir(path)
      |> detect_rust(path)
      |> detect_dart(path)
      |> detect_go(path)
      |> detect_python(path)
      |> detect_ruby(path)
      |> detect_docker_services(path)
      |> detect_typescript(path)
      |> detect_supabase_dir(path)
      |> detect_prisma_dir(path)
      |> detect_ci_cd(path)
      |> detect_monorepo(path)

    domains = detect_domains(path)
    suggested_agents = suggest_agents(domains, detections)

    tech_stack =
      %{}
      |> maybe_put(:language, detections.language)
      |> maybe_put(:framework, detections.framework)
      |> maybe_put(:database, detections.database)
      |> maybe_put(:styling, detections.styling)
      |> maybe_put(:testing, detections.testing)

    Map.merge(detections, %{
      domains: domains,
      suggested_agents: suggested_agents,
      tech_stack: tech_stack
    })
  end

  # ---------------------------------------------------------------------------
  # Node / JavaScript / TypeScript ecosystem
  # ---------------------------------------------------------------------------

  defp detect_node(detections, path) do
    package_json = Path.join(path, "package.json")

    if File.exists?(package_json) do
      case File.read(package_json) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, data} -> parse_package_json(detections, data, path)
            _ -> detect_package_manager(detections, path)
          end

        _ ->
          detect_package_manager(detections, path)
      end
    else
      detections
    end
  end

  defp parse_package_json(detections, data, path) do
    deps = Map.merge(data["dependencies"] || %{}, data["devDependencies"] || %{})
    dep_keys = Map.keys(deps)

    language = if Map.has_key?(deps, "typescript"), do: "TypeScript", else: "JavaScript"

    framework =
      cond do
        "nuxt" in dep_keys or "nuxt3" in dep_keys -> "Nuxt 3"
        "next" in dep_keys -> "Next.js"
        "react" in dep_keys and "next" not in dep_keys -> "React"
        "vue" in dep_keys and "nuxt" not in dep_keys -> "Vue"
        "@angular/core" in dep_keys -> "Angular"
        "svelte" in dep_keys -> "Svelte"
        "vite" in dep_keys -> "Vite"
        true -> nil
      end

    styling =
      cond do
        "tailwindcss" in dep_keys -> "Tailwind CSS"
        true -> detections.styling
      end

    testing =
      cond do
        "vitest" in dep_keys -> "Vitest"
        "jest" in dep_keys -> "Jest"
        "mocha" in dep_keys -> "Mocha"
        true -> detections.testing
      end

    database =
      cond do
        "prisma" in dep_keys or "@prisma/client" in dep_keys -> "Prisma"
        detections.database -> detections.database
        true -> nil
      end

    # Check for monorepo indicators in package.json
    monorepo =
      data["workspaces"] != nil or
        Map.has_key?(data, "lerna") or
        File.exists?(Path.join(path, "lerna.json")) or
        File.exists?(Path.join(path, "pnpm-workspace.yaml")) or
        File.exists?(Path.join(path, "turbo.json"))

    detections
    |> Map.put(:language, language)
    |> Map.put(:framework, framework)
    |> Map.put(:styling, styling)
    |> Map.put(:testing, testing)
    |> Map.put(:database, database)
    |> Map.put(:monorepo, monorepo || detections.monorepo)
    |> detect_package_manager(path)
  end

  defp detect_package_manager(detections, path) do
    pm =
      cond do
        File.exists?(Path.join(path, "bun.lockb")) -> "bun"
        File.exists?(Path.join(path, "pnpm-lock.yaml")) -> "pnpm"
        File.exists?(Path.join(path, "yarn.lock")) -> "yarn"
        File.exists?(Path.join(path, "package-lock.json")) -> "npm"
        true -> detections.package_manager
      end

    Map.put(detections, :package_manager, pm)
  end

  # ---------------------------------------------------------------------------
  # Elixir
  # ---------------------------------------------------------------------------

  defp detect_elixir(detections, path) do
    mix_exs = Path.join(path, "mix.exs")

    if File.exists?(mix_exs) do
      case File.read(mix_exs) do
        {:ok, content} ->
          language = detections.language || "Elixir"

          framework =
            cond do
              content =~ ~r/:phoenix/ -> "Phoenix"
              true -> detections.framework
            end

          database =
            cond do
              content =~ ~r/:ecto/ or content =~ ~r/:postgrex/ -> detections.database || "PostgreSQL"
              true -> detections.database
            end

          testing =
            cond do
              content =~ ~r/:ex_unit/ or File.dir?(Path.join(path, "test")) ->
                detections.testing || "ExUnit"

              true ->
                detections.testing
            end

          has_live_view = content =~ ~r/:phoenix_live_view/

          framework =
            if has_live_view and framework == "Phoenix",
              do: "Phoenix LiveView",
              else: framework

          detections
          |> Map.put(:language, language)
          |> Map.put(:framework, framework)
          |> Map.put(:database, database)
          |> Map.put(:testing, testing)

        _ ->
          detections
      end
    else
      detections
    end
  end

  # ---------------------------------------------------------------------------
  # Rust
  # ---------------------------------------------------------------------------

  defp detect_rust(detections, path) do
    if File.exists?(Path.join(path, "Cargo.toml")) do
      detections
      |> Map.put(:language, detections.language || "Rust")
    else
      detections
    end
  end

  # ---------------------------------------------------------------------------
  # Dart / Flutter
  # ---------------------------------------------------------------------------

  defp detect_dart(detections, path) do
    if File.exists?(Path.join(path, "pubspec.yaml")) do
      case File.read(Path.join(path, "pubspec.yaml")) do
        {:ok, content} ->
          framework =
            if content =~ ~r/flutter:/,
              do: "Flutter",
              else: detections.framework

          detections
          |> Map.put(:language, detections.language || "Dart")
          |> Map.put(:framework, framework)

        _ ->
          Map.put(detections, :language, detections.language || "Dart")
      end
    else
      detections
    end
  end

  # ---------------------------------------------------------------------------
  # Go
  # ---------------------------------------------------------------------------

  defp detect_go(detections, path) do
    if File.exists?(Path.join(path, "go.mod")) do
      Map.put(detections, :language, detections.language || "Go")
    else
      detections
    end
  end

  # ---------------------------------------------------------------------------
  # Python
  # ---------------------------------------------------------------------------

  defp detect_python(detections, path) do
    has_pyproject = File.exists?(Path.join(path, "pyproject.toml"))
    has_requirements = File.exists?(Path.join(path, "requirements.txt"))

    if has_pyproject or has_requirements do
      content =
        cond do
          has_pyproject -> File.read!(Path.join(path, "pyproject.toml"))
          has_requirements -> File.read!(Path.join(path, "requirements.txt"))
          true -> ""
        end

      framework =
        cond do
          content =~ ~r/django/i -> "Django"
          content =~ ~r/fastapi/i -> "FastAPI"
          content =~ ~r/flask/i -> "Flask"
          true -> detections.framework
        end

      testing =
        cond do
          content =~ ~r/pytest/i -> detections.testing || "pytest"
          true -> detections.testing
        end

      detections
      |> Map.put(:language, detections.language || "Python")
      |> Map.put(:framework, framework)
      |> Map.put(:testing, testing)
    else
      detections
    end
  end

  # ---------------------------------------------------------------------------
  # Ruby
  # ---------------------------------------------------------------------------

  defp detect_ruby(detections, path) do
    if File.exists?(Path.join(path, "Gemfile")) do
      case File.read(Path.join(path, "Gemfile")) do
        {:ok, content} ->
          framework =
            if content =~ ~r/rails/i,
              do: "Ruby on Rails",
              else: detections.framework

          detections
          |> Map.put(:language, detections.language || "Ruby")
          |> Map.put(:framework, framework)

        _ ->
          Map.put(detections, :language, detections.language || "Ruby")
      end
    else
      detections
    end
  end

  # ---------------------------------------------------------------------------
  # Docker / compose services
  # ---------------------------------------------------------------------------

  defp detect_docker_services(detections, path) do
    compose_file =
      cond do
        File.exists?(Path.join(path, "docker-compose.yml")) ->
          Path.join(path, "docker-compose.yml")

        File.exists?(Path.join(path, "docker-compose.yaml")) ->
          Path.join(path, "docker-compose.yaml")

        File.exists?(Path.join(path, "compose.yml")) ->
          Path.join(path, "compose.yml")

        File.exists?(Path.join(path, "compose.yaml")) ->
          Path.join(path, "compose.yaml")

        true ->
          nil
      end

    if compose_file do
      case File.read(compose_file) do
        {:ok, content} ->
          database =
            cond do
              content =~ ~r/supabase/ -> detections.database || "Supabase"
              content =~ ~r/postgres/ -> detections.database || "PostgreSQL"
              content =~ ~r/mongo/ -> detections.database || "MongoDB"
              content =~ ~r/mysql/ -> detections.database || "MySQL"
              true -> detections.database
            end

          # Detect Redis as an extra, not overriding database
          detections
          |> Map.put(:database, database)

        _ ->
          detections
      end
    else
      detections
    end
  end

  # ---------------------------------------------------------------------------
  # TypeScript (via tsconfig.json — upgrades language if JS was detected)
  # ---------------------------------------------------------------------------

  defp detect_typescript(detections, path) do
    if File.exists?(Path.join(path, "tsconfig.json")) do
      language =
        if detections.language in ["JavaScript", nil],
          do: "TypeScript",
          else: detections.language

      Map.put(detections, :language, language)
    else
      detections
    end
  end

  # ---------------------------------------------------------------------------
  # Supabase directory
  # ---------------------------------------------------------------------------

  defp detect_supabase_dir(detections, path) do
    if File.dir?(Path.join(path, "supabase")) do
      Map.put(detections, :database, detections.database || "Supabase")
    else
      detections
    end
  end

  # ---------------------------------------------------------------------------
  # Prisma directory
  # ---------------------------------------------------------------------------

  defp detect_prisma_dir(detections, path) do
    if File.dir?(Path.join(path, "prisma")) do
      Map.put(detections, :database, detections.database || "Prisma")
    else
      detections
    end
  end

  # ---------------------------------------------------------------------------
  # CI/CD
  # ---------------------------------------------------------------------------

  defp detect_ci_cd(detections, path) do
    has_ci =
      File.dir?(Path.join(path, ".github/workflows")) or
        File.exists?(Path.join(path, ".gitlab-ci.yml")) or
        File.exists?(Path.join(path, ".circleci/config.yml"))

    Map.put(detections, :ci_cd, has_ci)
  end

  # ---------------------------------------------------------------------------
  # Monorepo heuristics
  # ---------------------------------------------------------------------------

  defp detect_monorepo(detections, path) do
    mono =
      detections.monorepo or
        File.exists?(Path.join(path, "lerna.json")) or
        File.exists?(Path.join(path, "pnpm-workspace.yaml")) or
        File.exists?(Path.join(path, "turbo.json")) or
        File.exists?(Path.join(path, "nx.json"))

    Map.put(detections, :monorepo, mono)
  end

  # ---------------------------------------------------------------------------
  # Domain detection
  # ---------------------------------------------------------------------------

  @doc "Detects project domains based on directory structure."
  def detect_domains(path) do
    frontend_dirs = ["app", "components", "pages"]
    backend_core_dirs = ["lib", "src"]
    backend_service_dirs = ["supabase", "server", "api"]
    testing_dirs = ["test", "tests", "spec"]
    mobile_dirs = ["mobile", "ios", "android"]

    domains = []

    # Frontend
    frontend_paths =
      frontend_dirs
      |> Enum.filter(&File.dir?(Path.join(path, &1)))
      |> Enum.map(&"#{&1}/")

    domains =
      if frontend_paths != [] do
        [%{name: "frontend", description: "Frontend application", paths: frontend_paths} | domains]
      else
        domains
      end

    # Backend / core
    backend_core_paths =
      backend_core_dirs
      |> Enum.filter(&File.dir?(Path.join(path, &1)))
      |> Enum.map(&"#{&1}/")

    # Backend services
    backend_service_paths =
      backend_service_dirs
      |> Enum.filter(&File.dir?(Path.join(path, &1)))
      |> Enum.map(&"#{&1}/")

    all_backend_paths = backend_core_paths ++ backend_service_paths

    domains =
      if all_backend_paths != [] do
        [%{name: "backend", description: "Backend / core logic", paths: all_backend_paths} | domains]
      else
        domains
      end

    # Testing
    testing_paths =
      testing_dirs
      |> Enum.filter(&File.dir?(Path.join(path, &1)))
      |> Enum.map(&"#{&1}/")

    domains =
      if testing_paths != [] do
        [%{name: "testing", description: "Test suites", paths: testing_paths} | domains]
      else
        domains
      end

    # Mobile
    mobile_paths =
      mobile_dirs
      |> Enum.filter(&File.dir?(Path.join(path, &1)))
      |> Enum.map(&"#{&1}/")

    domains =
      if mobile_paths != [] do
        [%{name: "mobile", description: "Mobile application", paths: mobile_paths} | domains]
      else
        domains
      end

    Enum.reverse(domains)
  end

  # ---------------------------------------------------------------------------
  # Agent suggestions
  # ---------------------------------------------------------------------------

  @doc "Suggests agents based on detected domains and tech stack."
  def suggest_agents(domains, detections) do
    domain_names = Enum.map(domains, & &1.name)

    agents = [%{name: "pm", role: "Project Manager"}]

    agents =
      if "frontend" in domain_names do
        agents ++ [%{name: "senior_frontend", role: "Senior Frontend Developer", domain: "frontend"}]
      else
        agents
      end

    agents =
      if "backend" in domain_names do
        agents ++ [%{name: "senior_backend", role: "Senior Backend Developer", domain: "backend"}]
      else
        agents
      end

    agents =
      if "mobile" in domain_names do
        agents ++ [%{name: "senior_mobile", role: "Senior Mobile Developer", domain: "mobile"}]
      else
        agents
      end

    # If no specific domain devs were added (besides PM), add a generic senior dev
    agents =
      if length(agents) == 1 do
        agents ++ [%{name: "senior_dev", role: "Senior Developer"}]
      else
        agents
      end

    # Add QA if testing framework detected or testing domain exists
    agents =
      if detections.testing != nil or "testing" in domain_names do
        agents ++ [%{name: "qa", role: "QA Engineer"}]
      else
        agents
      end

    agents
  end

  # ---------------------------------------------------------------------------
  # Summary for display
  # ---------------------------------------------------------------------------

  @doc "Returns a human-readable summary of the detection results."
  def summary(result) do
    lines = []

    lines = if result.language, do: lines ++ ["Language:        #{result.language}"], else: lines
    lines = if result.framework, do: lines ++ ["Framework:       #{result.framework}"], else: lines
    lines = if result.database, do: lines ++ ["Database:        #{result.database}"], else: lines
    lines = if result.styling, do: lines ++ ["Styling:         #{result.styling}"], else: lines
    lines = if result.testing, do: lines ++ ["Testing:         #{result.testing}"], else: lines

    lines =
      if result.package_manager,
        do: lines ++ ["Package Manager: #{result.package_manager}"],
        else: lines

    lines = if result.monorepo, do: lines ++ ["Monorepo:        yes"], else: lines
    lines = if result.ci_cd, do: lines ++ ["CI/CD:           detected"], else: lines

    if result.domains != [] do
      domain_names = result.domains |> Enum.map(& &1.name) |> Enum.join(", ")
      lines = lines ++ ["Domains:         #{domain_names}"]
      lines
    else
      lines
    end
    |> Enum.join("\n")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
