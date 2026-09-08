defmodule ManaspritesDesktopWeb.LocalAuth do
  import Plug.Conn
  import Phoenix.LiveView

  def init(opts), do: opts

  def valid?(token) when is_binary(token),
    do: Plug.Crypto.secure_compare(token, ManaspritesDesktop.Bootstrap.token())

  def valid?(_), do: false

  def call(conn, _) do
    if valid?(get_session(conn, :local_token)),
      do: conn,
      else: conn |> send_resp(401, "Open Manasprites from the desktop app.") |> halt()
  end

  def on_mount(:default, _params, session, socket) do
    if valid?(session["local_token"]),
      do: {:cont, socket},
      else: {:halt, redirect(socket, to: "/launch")}
  end
end
