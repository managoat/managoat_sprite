defmodule ManaspritesDesktop.ObservedService do
  @moduledoc false
  def init(observer), do: observer

  def call(conn, observer) do
    send(observer, {:service_request, conn.method, conn.request_path})

    conn =
      Plug.Conn.register_before_send(conn, fn conn ->
        if conn.request_path == "/api/capabilities" and
             Application.get_env(:manasprites_desktop, :fixture_old_capabilities, false) do
          %{
            conn
            | resp_body: conn.resp_body |> Jason.decode!() |> Map.delete("a2a") |> Jason.encode!()
          }
        else
          conn
        end
      end)

    Managoat.Sprite.HTTP.call(conn, [])
  end
end
