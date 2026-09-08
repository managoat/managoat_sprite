defmodule ManaspritesDesktopWeb.LocalHost do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _) do
    expected = "http://127.0.0.1:#{conn.port}"

    if conn.host == "127.0.0.1" and get_req_header(conn, "origin") in [[], [expected]] do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header(
        "content-security-policy",
        "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' ws://127.0.0.1:#{conn.port}; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
      )
    else
      conn |> send_resp(403, "Local access only") |> halt()
    end
  end
end
