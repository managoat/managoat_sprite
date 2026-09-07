defmodule Managoat.Sprite.Application do
  use Application
  alias Managoat.Sprite.{Config, Repo, Store, Engine}
  @impl true
  def start(_, _) do
    if Application.get_env(:managoat_sprite, :boot, true) do
      config = Config.load!()
      Application.put_env(:managoat_sprite, :config, config)

      children =
        children(config) ++
          [
            {Bandit,
             plug: Managoat.Sprite.HTTP, port: config["port"], ip: parse_ip(config["host"])}
          ]

      Supervisor.start_link(children, strategy: :rest_for_one, name: Managoat.Sprite.Supervisor)
    else
      Supervisor.start_link([], strategy: :one_for_one)
    end
  end

  def children(_config) do
    state = Path.join(Config.root(), "state")
    File.mkdir_p!(state)
    File.chmod!(state, 0o700)

    [
      {Repo, database: Config.database_path!()},
      Store,
      Engine,
      {DynamicSupervisor, strategy: :one_for_one, name: Managoat.Sprite.Workers}
    ]
  end

  defp parse_ip(host) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(host))
    ip
  end
end
