defmodule ManaspritesDesktop.HeldAcknowledgement do
  @moduledoc false
  import Plug.Conn
  def init(opts), do: opts

  def call(%{method: "POST", request_path: "/api/conversations"} = conn, observer) do
    {:ok, body, conn} = read_body(conn)
    internal = Plug.Test.conn("POST", "/api/conversations", body)

    internal =
      Enum.reduce(
        Enum.reject(conn.req_headers, fn {key, _} -> key == "host" end),
        internal,
        fn {key, value}, c ->
          put_req_header(c, key, value)
        end
      )

    response = Managoat.Sprite.HTTP.call(internal, [])
    send(observer, {:accepted_without_ack, self()})

    receive do
      :release_ack -> :ok
    after
      10_000 -> :ok
    end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(response.status, response.resp_body)
  end

  def call(conn, _), do: Managoat.Sprite.HTTP.call(conn, [])
end
