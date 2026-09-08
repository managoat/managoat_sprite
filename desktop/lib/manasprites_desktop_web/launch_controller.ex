defmodule ManaspritesDesktopWeb.LaunchController do
  use Phoenix.Controller, formats: [:html]

  def show(conn, params) do
    if ManaspritesDesktopWeb.LocalAuth.valid?(params["token"]) do
      conn
      |> configure_session(renew: true)
      |> put_session(:local_token, params["token"])
      |> redirect(to: "/")
    else
      send_resp(conn, 401, "Open Manasprites from the desktop app.")
    end
  end
end
