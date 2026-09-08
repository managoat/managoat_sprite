# A real service in its own BEAM, with an actual ACP ScriptedAgent. Every path,
# key and prompt is synthetic; the parent owns the OS process group.
[root, ready, label] = System.argv()
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
    "runtime" => "claude",
    "workspace" => Path.join(root, "project"),
    "task_required" => false,
    "disk_reserve_bytes" => 0,
    "permissions" => %{"default" => "ask"}
  })

Application.put_env(:managoat_sprite, :config, config)
Application.put_env(:managoat_sprite, :runtime, ManaspritesDesktop.ServiceFixture)

Application.put_env(:managoat_sprite, :script,
  session_id: label <> "-session",
  capabilities: %{"sessionCapabilities" => %{"resume" => %{}}},
  permission: %{
    "toolCall" => %{"toolCallId" => "tool-1", "title" => "Edit " <> label, "kind" => "edit"},
    "options" => [%{"optionId" => "allow", "name" => "Allow once", "kind" => "allow_once"}]
  },
  updates: [
    %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => label <> " completed independently"}
    }
  ]
)

{:ok, _} = Application.ensure_all_started(:managoat_sprite)

{:ok, _} =
  Supervisor.start_link(Managoat.Sprite.Application.children(config), strategy: :rest_for_one)

:ok = Managoat.Sprite.Store.call({:key, "synthetic-" <> label})
{:ok, server} = Bandit.start_link(plug: Managoat.Sprite.HTTP, port: 0, ip: {127, 0, 0, 1})
{:ok, {_, port}} = ThousandIsland.listener_info(server)
File.write!(ready, Jason.encode!(%{port: port, pid: System.pid()}))
Process.sleep(:infinity)
