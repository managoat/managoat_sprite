defmodule Managoat.Sprite.Release do
  @moduledoc "Offline install/migration entry points and authenticated local operator commands."
  alias Managoat.Sprite.{Config, Runtime, Repo, Store, Lifecycle}

  def install do
    Application.put_env(:managoat_sprite, :boot, false)
    {:ok, _} = Application.ensure_all_started(:managoat_sprite)
    c = Config.load!()
    Application.put_env(:managoat_sprite, :config, c)
    Config.database_path!()
    hold = "managoat-install"

    Lifecycle.with_hold(hold, fn ->
      with :ok <- Runtime.install(), :ok <- Runtime.probe() do
        {:ok, _} = Repo.start_link(database: Config.database_path!())
        {:ok, _} = Store.start_link([])

        :ok =
          Store.call(
            {:key, File.read!(Path.join(Config.root(), "config/client.key")) |> String.trim()}
          )

        Config.private_write!(
          Path.join(Config.root(), "state/runtime-initialized.json"),
          Jason.encode!(Runtime.initialization_record())
        )

        IO.puts(
          Jason.encode!(%{installed: true, agent_initialized: true, inference_verified: false})
        )
      else
        _ ->
          IO.puts(:stderr, "runtime setup or ACP initialization failed; run managoat doctor")
          System.halt(1)
      end
    end)
  end

  def rotate_key do
    key = "mgt_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    :ok = Store.call({:key, key})
    Config.private_write!(Path.join(Config.root(), "config/client.key"), key <> "\n")
    :ok = Store.call({:rotate_key, key})
    :ok
  end

  def doctor do
    c = Config.load!()
    Application.put_env(:managoat_sprite, :config, c)
    {:ok, _} = Application.ensure_all_started(:erlexec)
    result = Runtime.probe()
    IO.puts(Jason.encode!(%{agent_initialized: result == :ok, inference_verified: false}))
    if result != :ok, do: System.halt(1)
  end
end
