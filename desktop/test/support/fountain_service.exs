[root, ready, runtime] = System.argv()
Logger.configure(level: :error)
System.put_env("MANAGOAT_ROOT", root)
Application.put_env(:managoat_sprite, :boot, false)

Application.put_env(:managoat_sprite, Managoat.Sprite.Repo,
  pool_size: 1,
  journal_mode: :wal,
  busy_timeout: 5000
)

config =
  Managoat.Sprite.Config.validate!(%{
    "runtime" => runtime,
    "workspace" => Path.join(root, "project"),
    "task_required" => false,
    "disk_reserve_bytes" => 0
  })

File.mkdir_p!(config["workspace"])
Application.put_env(:managoat_sprite, :config, config)
Application.put_env(:managoat_sprite, :runtime, ManaspritesDesktop.FountainProcessRuntime)
{:ok, _} = Application.ensure_all_started(:managoat_sprite)

{:ok, _} =
  Supervisor.start_link(Managoat.Sprite.Application.children(config), strategy: :rest_for_one)

:ok = Managoat.Sprite.Store.call({:key, "synthetic-service-key"})
{:ok, server} = Bandit.start_link(plug: Managoat.Sprite.HTTP, port: 0, ip: {127, 0, 0, 1})
{:ok, {_, port}} = ThousandIsland.listener_info(server)
File.write!(ready, Jason.encode!(%{port: port}))
Process.sleep(:infinity)
