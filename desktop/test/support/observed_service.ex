defmodule ManaspritesDesktop.ObservedService do
  @moduledoc false
  def init(observer), do: observer

  def call(conn, observer) do
    send(observer, {:service_request, conn.method, conn.request_path})
    Managoat.Sprite.HTTP.call(conn, [])
  end
end
