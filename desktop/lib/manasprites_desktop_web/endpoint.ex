defmodule ManaspritesDesktopWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :manasprites_desktop

  @session [
    store: :cookie,
    key: "_manasprites_desktop",
    signing_salt: "local-session",
    same_site: "Strict",
    http_only: true
  ]
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session]],
    longpoll: false

  plug ManaspritesDesktopWeb.LocalHost
  plug Plug.Static, at: "/", from: :manasprites_desktop, only: ~w(assets)
  plug Plug.Parsers, parsers: [:urlencoded], pass: [], length: 1_048_576
  plug Plug.Session, @session
  plug ManaspritesDesktopWeb.Router
end
