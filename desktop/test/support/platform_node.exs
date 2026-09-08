# Synthetic platform plus a real service, ACP peer, Python reader and Git tree.
# Installation alone is emulated; no account, provider or external network access.
[root, ready] = System.argv()
Logger.configure(level: :error)
System.put_env("MANAGOAT_ROOT", Path.join(root, ".local/share/managoat"))
Application.put_env(:managoat_sprite, :boot, false)

Application.put_env(:managoat_sprite, Managoat.Sprite.Repo,
  pool_size: 1,
  journal_mode: :wal,
  busy_timeout: 5000
)

project = Path.join(root, "project")
File.mkdir_p!(project)

git = fn args ->
  {_, 0} = System.cmd("git", ["-C", project] ++ args, stderr_to_stdout: true)
end

git.(["init", "--quiet"])
git.(["config", "user.name", "Native qualification"])
git.(["config", "user.email", "qualification@example.invalid"])
File.write!(Path.join(project, "proof.txt"), "baseline\n")
git.(["add", "proof.txt"])
git.(["commit", "--quiet", "-m", "Synthetic baseline"])
File.write!(Path.join(project, "proof.txt"), "staged\n", [:append])
git.(["add", "proof.txt"])
File.write!(Path.join(project, "proof.txt"), "unstaged\n", [:append])
File.write!(Path.join(root, "outside.txt"), "Synthetic outside-workspace file")
File.ln_s!(Path.join(root, "outside.txt"), Path.join(project, "outside-link"))

config =
  Managoat.Sprite.Config.validate!(%{
    "runtime" => "codex",
    "workspace" => project,
    "task_required" => false,
    "disk_reserve_bytes" => 0
  })

Application.put_env(:managoat_sprite, :config, config)
Application.put_env(:managoat_sprite, :runtime, ManaspritesDesktop.ServiceFixture)

Application.put_env(:managoat_sprite, :script,
  capabilities: %{"sessionCapabilities" => %{"resume" => %{}}},
  updates: [
    %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{
        "type" => "text",
        "text" =>
          "The project has staged and unstaged changes in proof.txt. Review the diff before committing."
      }
    }
  ]
)

{:ok, _} = Application.ensure_all_started(:managoat_sprite)

{:ok, _} =
  Supervisor.start_link(Managoat.Sprite.Application.children(config), strategy: :rest_for_one)

{:ok, service} = Bandit.start_link(plug: Managoat.Sprite.HTTP, port: 0, ip: {127, 0, 0, 1})
{:ok, {_, service_port}} = ThousandIsland.listener_info(service)
owner = self()

{:ok, fixture} =
  Agent.start_link(fn ->
    %{
      owner: owner,
      service_url: "http://127.0.0.1:#{service_port}",
      catalogue: [
        %{"name" => "first", "org_slug" => "test-org"},
        %{"name" => "second", "org_slug" => "test-org"}
      ],
      sprites: %{},
      creates: 0,
      lose_create: false,
      home: root,
      emulate_install: true,
      write_installed_config: true
    }
  end)

{:ok, platform} =
  Bandit.start_link(
    plug: {ManaspritesDesktop.PlatformFixture, fixture},
    port: 0,
    ip: {127, 0, 0, 1}
  )

{:ok, {_, port}} = ThousandIsland.listener_info(platform)
File.write!(ready, Jason.encode!(%{port: port, pid: System.pid()}))
Process.sleep(:infinity)
