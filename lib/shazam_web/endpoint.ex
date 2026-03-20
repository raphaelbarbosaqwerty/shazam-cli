defmodule ShazamWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :shazam

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  @session_options [
    store: :cookie,
    key: "_shazam_key",
    signing_salt: "shazam_sign",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  # Serve static files from priv/static
  plug Plug.Static,
    at: "/",
    from: :shazam,
    gzip: false,
    only: ShazamWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head

  # Legacy WebSocket — intercept /ws before Phoenix routing
  plug ShazamWeb.Plugs.LegacyWebSocket

  plug Plug.Session, @session_options
  plug ShazamWeb.Router
end
