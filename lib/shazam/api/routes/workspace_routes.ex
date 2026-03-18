defmodule Shazam.API.Routes.WorkspaceRoutes do
  @moduledoc "Handles all /api/workspace/* endpoints. Forwarded with prefix /api/workspace stripped."

  use Plug.Router

  import Shazam.API.Helpers

  @ignored_dirs ~w(.git .github node_modules _build deps .elixir_ls .dart_tool build .flutter-plugins .idea .vscode __pycache__ .cache .shazam)

  plug :match
  plug :dispatch

  post "/" do
    %{"path" => path} = conn.body_params

    if File.dir?(path) do
      Application.put_env(:shazam, :workspace, path)
      Shazam.Store.save("workspace", %{"path" => path})
      add_workspace_to_history(path)
      Shazam.SkillMemory.init()
      json(conn, 200, %{status: "ok", workspace: path})
    else
      json(conn, 422, %{error: "Directory not found: #{path}"})
    end
  end

  get "/" do
    path = Application.get_env(:shazam, :workspace, nil)
    json(conn, 200, %{workspace: path})
  end

  get "/diff/:commit_count" do
    workspace = Application.get_env(:shazam, :workspace, nil)

    if workspace && File.dir?(Path.join(workspace, ".git")) do
      n = String.to_integer(commit_count)
      {diff_output, _exit} = System.cmd("git", ["diff", "HEAD~#{n}"], cd: workspace, stderr_to_stdout: true)
      json(conn, 200, %{diff: diff_output, commit_count: n})
    else
      json(conn, 422, %{error: "No workspace set or not a git repository"})
    end
  end

  get "/diff" do
    workspace = Application.get_env(:shazam, :workspace, nil)

    if workspace && File.dir?(Path.join(workspace, ".git")) do
      {diff_output, _exit} = System.cmd("git", ["diff", "HEAD"], cd: workspace, stderr_to_stdout: true)
      json(conn, 200, %{diff: diff_output})
    else
      json(conn, 422, %{error: "No workspace set or not a git repository"})
    end
  end

  get "/skills" do
    workspace = Application.get_env(:shazam, :workspace, nil)

    if workspace do
      skills = list_project_skills(workspace)
      json(conn, 200, %{skills: skills})
    else
      json(conn, 422, %{error: "No workspace set"})
    end
  end

  get "/dirs" do
    workspace = Application.get_env(:shazam, :workspace, nil)

    if workspace do
      max_depth = String.to_integer(conn.query_params["depth"] || "3")
      dirs = list_dirs(workspace, workspace, max_depth, 0)
      json(conn, 200, %{workspace: workspace, dirs: dirs})
    else
      json(conn, 422, %{error: "No workspace set"})
    end
  end

  get "/files" do
    workspace = Application.get_env(:shazam, :workspace, nil)
    rel_path = conn.query_params["path"] || ""

    if workspace do
      target = if rel_path == "", do: workspace, else: Path.join(workspace, rel_path)

      if File.dir?(target) do
        case File.ls(target) do
          {:ok, entries} ->
            items =
              entries
              |> Enum.reject(&String.starts_with?(&1, "."))
              |> Enum.reject(&Enum.member?(@ignored_dirs, &1))
              |> Enum.map(fn name ->
                full = Path.join(target, name)
                relative = Path.relative_to(full, workspace)
                type = if File.dir?(full), do: "directory", else: "file"
                %{name: name, type: type, path: relative}
              end)
              |> Enum.sort_by(fn e -> {if(e.type == "directory", do: 0, else: 1), e.name} end)

            json(conn, 200, %{entries: items, path: rel_path})

          _ ->
            json(conn, 422, %{error: "Cannot read directory"})
        end
      else
        json(conn, 404, %{error: "Not a directory: #{rel_path}"})
      end
    else
      json(conn, 422, %{error: "No workspace set"})
    end
  end

  match _ do
    json(conn, 404, %{error: "Not found"})
  end

  # --- Private helpers ---

  defp list_dirs(base, dir, max_depth, current_depth) do
    if current_depth >= max_depth do
      []
    else
      case File.ls(dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(fn entry -> !Enum.member?(@ignored_dirs, entry) end)
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.filter(&File.dir?/1)
          |> Enum.sort()
          |> Enum.map(fn full_path ->
            relative = Path.relative_to(full_path, base)
            children = list_dirs(base, full_path, max_depth, current_depth + 1)
            %{name: Path.basename(full_path), path: relative, children: children}
          end)

        _ ->
          []
      end
    end
  end

  defp list_project_skills(workspace) do
    commands_dir = Path.join(workspace, ".claude/commands")

    if File.dir?(commands_dir) do
      flat_skills =
        commands_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(fn filename ->
          path = Path.join(commands_dir, filename)
          name = String.replace_suffix(filename, ".md", "")
          content = File.read!(path)
          %{id: name, name: name, content: content, source: "file"}
        end)

      dir_skills =
        commands_dir
        |> File.ls!()
        |> Enum.map(&Path.join(commands_dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.filter(fn dir -> File.exists?(Path.join(dir, "SKILL.md")) end)
        |> Enum.map(fn dir ->
          name = Path.basename(dir)
          content = File.read!(Path.join(dir, "SKILL.md"))
          %{id: name, name: name, content: content, source: "directory"}
        end)

      flat_skills ++ dir_skills
    else
      []
    end
  end
end
