defmodule Managoat.Sprite.Lifecycle do
  @moduledoc "Finite Sprite task holds. The application never stores a platform token."
  alias Managoat.Sprite.Config
  def acquire(name), do: request(:put, name)
  def release(name), do: request(:delete, name)

  defp request(method, name) do
    c = Config.get()

    if c["task_required"] do
      opts = [
        method: method,
        url: "http://sprite/v1/tasks/" <> URI.encode(name),
        unix_socket: c["task_socket"],
        receive_timeout: 5_000,
        retry: false
      ]

      opts = if method == :put, do: Keyword.put(opts, :json, %{expire: "5m"}), else: opts

      case Req.request(opts) do
        {:ok, %{status: code}} when code in [200, 201, 204] -> :ok
        {:ok, %{status: 404}} when method == :delete -> :ok
        _ -> {:error, :sprite_hold_unavailable}
      end
    else
      :ok
    end
  end
end
