defmodule Managoat.Sprite.Lifecycle do
  @moduledoc "Finite Sprite task holds. The application never stores a platform token."
  alias Managoat.Sprite.Config
  def acquire(name), do: request(:put, name)
  def release(name), do: request(:delete, name)

  def with_hold(name, fun) do
    :ok = acquire(name)
    owner = self()

    renewer =
      spawn_link(fn -> renew_install(name, owner, System.monotonic_time(:millisecond)) end)

    try do
      fun.()
    after
      Process.unlink(renewer)
      Process.exit(renewer, :kill)
      release(name)
    end
  end

  defp renew_install(name, owner, confirmed) do
    receive do
    after
      60_000 ->
        if Process.alive?(owner) do
          case acquire(name) do
            :ok ->
              renew_install(name, owner, System.monotonic_time(:millisecond))

            _ ->
              if System.monotonic_time(:millisecond) - confirmed >= 240_000,
                do: exit(:sprite_hold_lost),
                else: renew_install(name, owner, confirmed)
          end
        end
    end
  end

  def reconcile(identity) do
    c = Config.get()

    if c["task_required"] do
      case Req.get("http://sprite/v1/tasks",
             unix_socket: c["task_socket"],
             receive_timeout: 5_000,
             retry: false
           ) do
        {:ok, %{status: 200, body: %{"tasks" => tasks}}} ->
          prefix = "managoat-" <> identity <> "-"

          Enum.reduce_while(tasks, :ok, fn task, _ ->
            if String.starts_with?(task["name"], prefix) do
              case release(task["name"]) do
                :ok -> {:cont, :ok}
                error -> {:halt, error}
              end
            else
              {:cont, :ok}
            end
          end)

        _ ->
          {:error, :sprite_hold_unavailable}
      end
    else
      :ok
    end
  end

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
