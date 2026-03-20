defmodule ShazamWeb.Plugs.LegacyWebSocket do
  @moduledoc """
  Intercepts GET /ws requests and upgrades them to the existing
  Shazam.API.WebSocket handler, preserving backward compatibility.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET", request_path: "/ws"} = conn, _opts) do
    conn
    |> WebSockAdapter.upgrade(Shazam.API.WebSocket, [], timeout: :infinity)
    |> halt()
  end

  def call(conn, _opts), do: conn
end
