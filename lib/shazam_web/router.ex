defmodule ShazamWeb.Router do
  use ShazamWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ShazamWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug CORSPlug, origin: ["*"]
  end

  # API routes — forward to existing sub-routers
  scope "/api", Shazam.API.Routes do
    pipe_through :api

    forward "/companies", CompanyRoutes
    forward "/tasks", TaskRoutes
    forward "/ralph-loop", RalphRoutes
    forward "/workspace", WorkspaceRoutes
    forward "/skills", SkillRoutes
    forward "/", MiscRoutes
  end

  # LiveView routes
  live_session :default, on_mount: [] do
    scope "/", ShazamWeb do
      pipe_through :browser

      live "/", FeedLive, :index
      live "/tasks", TasksLive, :index
      live "/agents", AgentsLive, :index
      live "/dashboard", DashboardLive, :index
      live "/config", ConfigLive, :index
    end
  end

  # Enable LiveDashboard in dev
  if Mix.env() in [:dev, :test] do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: ShazamWeb.Telemetry
    end
  end
end
