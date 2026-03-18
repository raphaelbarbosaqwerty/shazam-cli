defmodule Shazam.API.Routes.SkillRoutes do
  @moduledoc "Handles all /api/skills/* endpoints. Forwarded with prefix /api/skills stripped."

  use Plug.Router

  import Shazam.API.Helpers

  plug :match
  plug :dispatch

  get "/" do
    skills = Shazam.SkillMemory.list_all()
    json(conn, 200, %{skills: skills})
  end

  post "/init" do
    case Shazam.SkillMemory.init() do
      {:ok, dir} -> json(conn, 200, %{status: "ok", directory: dir})
      {:error, reason} -> json(conn, 422, %{error: inspect(reason)})
    end
  end

  get "/*path" do
    relative = Enum.join(path, "/")
    case Shazam.SkillMemory.read_skill(relative) do
      {:ok, {frontmatter, content}} ->
        json(conn, 200, %{path: relative, frontmatter: frontmatter, content: content})
      {:error, reason} ->
        json(conn, 404, %{error: inspect(reason)})
    end
  end

  put "/*path" do
    relative = Enum.join(path, "/")
    %{"content" => content} = conn.body_params
    frontmatter = conn.body_params["frontmatter"] || %{}

    case Shazam.SkillMemory.write_skill(relative, frontmatter, content) do
      :ok -> json(conn, 200, %{status: "ok"})
      {:error, reason} -> json(conn, 422, %{error: inspect(reason)})
    end
  end

  delete "/*path" do
    relative = Enum.join(path, "/")
    case Shazam.SkillMemory.skill_path(relative) do
      nil -> json(conn, 422, %{error: "no workspace"})
      full_path ->
        case File.rm(full_path) do
          :ok -> json(conn, 200, %{status: "deleted"})
          {:error, reason} -> json(conn, 422, %{error: inspect(reason)})
        end
    end
  end

  match _ do
    json(conn, 404, %{error: "Not found"})
  end
end
