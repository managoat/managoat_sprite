defmodule ManaspritesDesktop.PlatformTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias ManaspritesDesktop.{Bootstrap, Fleet, Platform, RemoteExec, Vault, Repo, Job}
  @endpoint ManaspritesDesktopWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:erlexec)
    root = Path.join(System.tmp_dir!(), "manasprites-platform-#{Ecto.UUID.generate()}")
    Application.put_env(:manasprites_desktop, :root, Path.join(root, "desktop"))

    start_supervised!(%{
      id: :desktop,
      start:
        {Supervisor, :start_link,
         [ManaspritesDesktop.Application.children(), [strategy: :rest_for_one]]},
      type: :supervisor
    })

    Phoenix.PubSub.subscribe(ManaspritesDesktop.PubSub, "fleet")
    System.put_env("MANAGOAT_ROOT", Path.join(root, "service"))

    config =
      Managoat.Sprite.Config.validate!(%{
        "runtime" => "codex",
        "workspace" => Path.join(root, "project"),
        "task_required" => false,
        "disk_reserve_bytes" => 0
      })

    Application.put_env(:managoat_sprite, :config, config)

    Application.put_env(:managoat_sprite, Managoat.Sprite.Repo,
      pool_size: 1,
      journal_mode: :wal,
      busy_timeout: 5000
    )

    Application.put_env(:managoat_sprite, :runtime, ManaspritesDesktop.ServiceFixture)

    Application.put_env(:managoat_sprite, :script,
      observer: self(),
      updates: [
        %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "Created agent response"}
        }
      ]
    )

    start_supervised!(%{
      id: :sprite,
      start:
        {Supervisor, :start_link,
         [Managoat.Sprite.Application.children(config), [strategy: :rest_for_one]]},
      type: :supervisor
    })

    eventually(fn -> assert Managoat.Sprite.Engine.ready?() end)
    server = start_supervised!({Bandit, plug: Managoat.Sprite.HTTP, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    owner = self()

    fixture =
      start_supervised!(
        {Agent,
         fn ->
           %{
             owner: owner,
             service_url: "http://127.0.0.1:#{port}",
             catalogue: [
               %{"name" => "first", "org_slug" => "test-org"},
               %{"name" => "second", "org_slug" => "test-org"}
             ],
             sprites: %{},
             creates: 0,
             lose_create: false,
             home: root,
             emulate_install: true
           }
         end}
      )

    platform =
      start_supervised!(
        {Bandit,
         plug: {ManaspritesDesktop.PlatformFixture, fixture}, port: 0, ip: {127, 0, 0, 1}},
        id: :platform_http
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(platform)
    Application.put_env(:manasprites_desktop, :platform_url, "http://127.0.0.1:#{port}")
    :ok = Vault.put("sprites", "test-org/token/synthetic-secret")
    :ok = Vault.put("openai", "synthetic-model-key")

    on_exit(fn ->
      Application.delete_env(:manasprites_desktop, :platform_url)
      System.delete_env("MANAGOAT_ROOT")
      File.rm_rf!(root)
    end)

    %{fixture: fixture, root: root}
  end

  test "LiveView discovers every page and creates an agent that can accept real ACP work", %{
    fixture: fixture
  } do
    conn = %{build_conn() | host: "127.0.0.1"} |> get("/launch", %{token: Bootstrap.token()})
    {:ok, view, _} = conn |> recycle() |> live("/")
    view |> element("#platform-open") |> render_click()
    view |> element("#discover-sprites") |> render_click()
    eventually(fn -> assert has_element?(view, ".catalogue-row", "second") end)
    view |> form("#create-sprite-form", attrs()) |> render_submit()

    eventually(fn ->
      assert Enum.any?(Platform.jobs(), &(&1.kind == "create" and &1.state == "completed"))
    end)

    assert_receive {:setup_received, ["OPENAI_API_KEY"]}
    [agent] = Fleet.list()
    eventually(fn -> assert Fleet.get(agent.id).status == "ready" end)
    assert agent.sprite_name == "new-agent"
    assert Agent.get(fixture, & &1.creates) == 1
    assert {:ok, _} = Fleet.submit(agent.id, "prompt", %{"prompt" => "Work on my project"})
    assert_receive {:scripted_agent, :wrote, %{"method" => "session/prompt"}}, 5000
    refute render(view) =~ "synthetic-model-key"
    refute render(view) =~ "synthetic-secret"
  end

  test "lost create response resumes the owned Sprite without creating another", %{
    fixture: fixture
  } do
    Agent.update(fixture, &%{&1 | lose_create: true})
    {:ok, job} = Platform.create(attrs())
    eventually(fn -> assert Platform.get(job.id).state == "failed" end)
    assert Platform.get(job.id).stage == "creating"
    assert Agent.get(fixture, & &1.creates) == 1
    assert :ok = Platform.retry(job.id)
    eventually(fn -> assert Platform.get(job.id).state == "completed" end)
    assert Agent.get(fixture, & &1.creates) == 1
    assert length(Fleet.list()) == 1
  end

  test "private creation and existing-agent attachment run real ACP through short-lived TCP relays",
       %{fixture: fixture} do
    conn = %{build_conn() | host: "127.0.0.1"} |> get("/launch", %{token: Bootstrap.token()})
    {:ok, view, _} = conn |> recycle() |> live("/")
    view |> element("#platform-open") |> render_click()
    view |> form("#create-sprite-form", Map.put(attrs(), "url_auth", "sprite")) |> render_submit()

    eventually(fn ->
      assert Enum.any?(Platform.jobs(), &(&1.state == "completed" and &1.kind == "create"))
    end)

    [agent] = Fleet.list()
    eventually(fn -> assert Fleet.get(agent.id).status == "ready" end)
    assert agent.transport == "private"

    assert Agent.get(fixture, &get_in(&1, [:sprites, "new-agent", "url_settings", "auth"])) ==
             "sprite"

    assert {:ok, _} = Fleet.submit(agent.id, "prompt", %{"prompt" => "Work privately"})
    assert_receive {:scripted_agent, :wrote, %{"method" => "session/prompt"}}, 5000

    eventually(fn ->
      assert Enum.any?(Fleet.jobs(agent.id), &(&1.kind == "prompt" and &1.state == "completed"))
      refute Fleet.busy?(Fleet.get(agent.id))
    end)

    # Every WebSocket forwards to the real service over a real local TCP socket.
    # Once idle, no relay or polling request remains to keep a Sprite awake.
    assert_receive {:proxy_open, first_proxy, 8080}
    assert_receive {:proxy_closed, ^first_proxy}, 5000
    assert_all_proxies_closed()
    drain_platform_requests()
    refute_receive {:platform_request, _, _}, 1000

    {:ok, key} = Vault.get("agent:" <> agent.id)
    assert :ok = Fleet.remove(agent.id)
    Agent.update(fixture, &%{&1 | catalogue: [%{"name" => "new-agent"}]})

    if not has_element?(view, "#discover-sprites"),
      do: view |> element("#platform-open") |> render_click()

    view |> element("#discover-sprites") |> render_click()

    eventually(fn ->
      assert has_element?(view, ".catalogue-row button[phx-value-name=new-agent]")
    end)

    view |> element(".catalogue-row button[phx-value-name=new-agent]") |> render_click()
    assert has_element?(view, "#connect-form input[name=organization][value=test-org]")
    assert has_element?(view, "#connect-form input[name=sprite_name][value=new-agent]")
    refute has_element?(view, "#connect-form input[name=url]")

    view
    |> form("#connect-form", %{
      "name" => "Existing private agent",
      "organization" => "test-org",
      "transport" => "private",
      "sprite_name" => "new-agent",
      "port" => "8080",
      "secret" => key
    })
    |> render_submit()

    eventually(fn -> assert [%{status: "ready", transport: "private"}] = Fleet.list() end)
    [attached] = Fleet.list()
    assert attached.sprite_id == agent.sprite_id
    eventually(fn -> assert Enum.all?(Fleet.jobs(attached.id), &(&1.state == "completed")) end)
    assert_all_proxies_closed()

    Agent.update(fixture, &put_in(&1, [:sprites, "new-agent", "id"], "replacement"))
    drain_platform_requests()

    assert {:error, :private_connection} =
             ManaspritesDesktop.ServiceClient.request(attached, :get, "/api/agents")

    refute_receive {:platform_request, "GET", "/v1/sprites/new-agent/proxy"}, 100
  end

  test "private relays close their WebSocket and listener when their job owner dies" do
    owner = self()

    task =
      spawn(fn ->
        ManaspritesDesktop.PrivateProxy.with_url(
          "test-org/token/synthetic-secret",
          "test-agent",
          8080,
          fn url ->
            port = URI.parse(url).port
            {:ok, _} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
            send(owner, {:local_relay, port})

            receive do
              :finish -> :ok
            end
          end
        )
      end)

    assert_receive {:local_relay, port}
    assert_receive {:proxy_open, proxy, 8080}, 5000
    ref = Process.monitor(proxy)
    Process.exit(task, :kill)
    assert_receive {:proxy_closed, ^proxy}, 5000
    assert_receive {:DOWN, ^ref, :process, ^proxy, _}, 5000

    assert {:error, :econnrefused} =
             :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    assert {:error, :connection_failed} =
             ManaspritesDesktop.PrivateProxy.with_url(
               "test-org/token/invalid",
               "test-agent",
               8080,
               fn url ->
                 ManaspritesDesktop.ServiceClient.request_with_key(
                   url,
                   "synthetic-key",
                   :get,
                   "/api/agents"
                 )
               end
             )
  end

  test "private relay refuses an untrusted TLS endpoint before sending platform credentials", %{
    fixture: fixture,
    root: root
  } do
    cert = Path.join(root, "test-cert.pem")
    key = Path.join(root, "test-key.pem")

    args = [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      key,
      "-out",
      cert,
      "-days",
      "1",
      "-subj",
      "/CN=localhost"
    ]

    {_, 0} = System.cmd("openssl", args, stderr_to_stdout: true)

    tls =
      start_supervised!(
        {Bandit,
         plug: {ManaspritesDesktop.PlatformFixture, fixture},
         scheme: :https,
         certfile: cert,
         keyfile: key,
         port: 0,
         ip: {127, 0, 0, 1}},
        id: :untrusted_platform
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(tls)
    Application.put_env(:manasprites_desktop, :platform_url, "https://127.0.0.1:#{port}")

    assert {:error, :connection_failed} =
             ManaspritesDesktop.PrivateProxy.with_url(
               "test-org/token/synthetic-secret",
               "test-agent",
               8080,
               fn url ->
                 ManaspritesDesktop.ServiceClient.request_with_key(
                   url,
                   "synthetic-key",
                   :get,
                   "/api/agents"
                 )
               end
             )

    refute_receive {:platform_request, _, _}, 100
  end

  test "foreign names and wrong-organization credentials cannot be adopted", %{fixture: fixture} do
    Agent.update(
      fixture,
      &put_in(&1, [:sprites, "new-agent"], %{
        "name" => "new-agent",
        "organization" => "test-org",
        "id" => "unowned",
        "labels" => []
      })
    )

    {:ok, job} = Platform.create(attrs())
    eventually(fn -> assert Platform.get(job.id).state == "failed" end)
    assert Platform.get(job.id).error =~ "different Sprite"
    assert Agent.get(fixture, & &1.creates) == 0

    assert {:error, :wrong_organization} =
             Platform.create(Map.put(attrs(), "organization", "wrong-org"))

    assert Fleet.list() == []
  end

  test "a repaired platform token resumes setup and completed jobs discard recovery secrets" do
    :ok = Vault.put("sprites", "test-org/token/invalid")
    {:ok, job} = Platform.create(attrs())
    eventually(fn -> assert Platform.get(job.id).state == "failed" end)
    assert Platform.get(job.id).error =~ "rejected"
    :ok = Vault.put("sprites", "test-org/token/synthetic-secret")
    assert :ok = Platform.retry(job.id)
    eventually(fn -> assert Platform.get(job.id).state == "completed" end)
    assert {:error, :credential_missing} = Vault.get("platform:" <> job.id)
    assert {:ok, _} = Vault.get("agent:" <> job.id)
  end

  test "SDK exec carries stdin through a real local subprocess and cleans up when its job exits" do
    token = "test-org/token/synthetic-secret"
    script = "import json,sys; p=json.load(sys.stdin); print(json.dumps({'echo':p['value']}))"

    assert {:ok, %{"echo" => "input with spaces"}} =
             RemoteExec.run(
               token,
               "fixture",
               "python3",
               ["-c", script],
               Jason.encode!(%{value: "input with spaces"})
             )

    assert_receive {:local_exec, _}

    task =
      Task.async(fn ->
        RemoteExec.run(token, "fixture", "python3", ["-c", "import time; time.sleep(60)"], "")
      end)

    assert_receive {:local_exec, process}, 5000
    monitor = Process.monitor(process)
    Task.shutdown(task, :brutal_kill)
    assert_receive {:DOWN, ^monitor, :process, ^process, _}, 5000
  end

  test "the packaged setup source and stdin envelope execute in a real Python process", %{
    fixture: fixture,
    root: root
  } do
    Agent.update(fixture, &%{&1 | emulate_install: false})

    assert {:ok, %{"ok" => false, "error" => "setup_incomplete"}} =
             RemoteExec.setup("test-org/token/synthetic-secret", "fixture", %{
               "action" => "status",
               "operation_id" => "synthetic-operation",
               "config" => %{},
               "client_key_hash" => "synthetic-hash"
             })

    assert File.stat!(Path.join(root, ".managoat-provision")).mode |> Bitwise.band(0o777) == 0o700
  end

  test "the inspector links the correct Sprite, previews files and reviews real Git changes",
       context do
    {aid, project} = workspace_fixture(context)
    git(project, ["init", "-q"])
    File.write!(Path.join(project, "README.md"), "original\n")
    File.write!(Path.join(project, "staged.txt"), "before staging\n")
    git(project, ["add", "."])

    git(project, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.test",
      "commit",
      "-qm",
      "fixture"
    ])

    File.write!(Path.join(project, "README.md"), "changed project\n")
    File.write!(Path.join(project, "staged.txt"), "staged change\n")
    git(project, ["add", "staged.txt"])
    index = File.read!(Path.join(project, ".git/index"))
    conn = %{build_conn() | host: "127.0.0.1"} |> get("/launch", %{token: Bootstrap.token()})
    {:ok, view, _} = conn |> recycle() |> live("/")
    view |> element("#agent-nav-#{aid}") |> render_click()

    view
    |> form("#link-workspace-form", %{sprite_name: "workspace-agent", organization: "test-org"})
    |> render_submit()

    eventually(fn -> assert has_element?(view, "#workspace-files button", "README.md") end)
    view |> element("#workspace-files button[phx-value-path='README.md']") |> render_click()
    eventually(fn -> assert has_element?(view, "#workspace-file pre", "changed project") end)
    view |> element("#inspector-tab-changes") |> render_click()
    view |> element("#refresh-inspector") |> render_click()
    eventually(fn -> assert has_element?(view, "#workspace-changes .change-row", "README.md") end)
    view |> element("#workspace-changes button", "Unstaged diff") |> render_click()
    eventually(fn -> assert has_element?(view, "#workspace-diff pre", "+changed project") end)
    view |> element("#inspector-tab-changes") |> render_click()
    view |> element("#workspace-changes button", "Staged diff") |> render_click()
    eventually(fn -> assert has_element?(view, "#workspace-diff pre", "+staged change") end)
    assert File.read!(Path.join(project, ".git/index")) == index
    assert File.stat!(Fleet.get(aid).workspace).inode == File.stat!(project).inode
    assert Fleet.get(aid).sprite_id == "workspace-identity"
    view |> element("#workspace-toggle") |> render_click()
    assert has_element?(view, ".workbench.inspector-wide #workspace-inspector")
    drain_platform_requests()
    {:ok, second, _} = conn |> recycle() |> live("/")
    second |> element("#agent-nav-#{aid}") |> render_click()
    assert has_element?(second, "#workspace-files button", "README.md")
    refute_receive {:platform_request, _, _}, 1000
  end

  test "workspace reads reject escaped paths and links, bound previews, and suppress binary content",
       context do
    {aid, project} = workspace_fixture(context)
    link_workspace(aid)
    File.write!(Path.join(context.root, "outside.txt"), "outside the workspace")
    File.ln_s!(Path.join(context.root, "outside.txt"), Path.join(project, "linked.txt"))
    File.write!(Path.join(project, "binary.bin"), <<0, 1, 2, 3>>)
    File.write!(Path.join(project, "large.txt"), String.duplicate("é", 100_000))

    assert {:error, :invalid_request} =
             Fleet.submit(aid, "workspace", %{"action" => "file", "path" => "../outside.txt"})

    assert {:error, :invalid_request} =
             Fleet.submit(aid, "workspace", %{"action" => "file", "path" => ".git/config"})

    assert {:error, {:inspection, "invalid_path"}} =
             ManaspritesDesktop.Workspace.run(Fleet.get(aid), %{
               "action" => "file",
               "path" => "../outside.txt"
             })

    {_, 0} = System.cmd("mkfifo", [Path.join(project, "pipe")])
    assert inspect_job(aid, "file", "pipe").state == "failed"

    linked = inspect_job(aid, "file", "linked.txt")
    assert linked.state == "failed"
    refute Jason.encode!(linked.result) =~ "outside the workspace"
    assert %{"binary" => true, "size" => 4} = inspect_job(aid, "file", "binary.bin").result
    large = inspect_job(aid, "file", "large.txt").result
    assert large["truncated"]
    assert String.valid?(large["text"])
    assert byte_size(large["text"]) <= 128 * 1024
    many = Path.join(project, "many")
    File.mkdir!(many)
    for index <- 1..1001, do: File.write!(Path.join(many, "file-#{index}"), "")
    listing = inspect_job(aid, "list", "many").result
    assert listing["truncated"]
    assert length(listing["entries"]) == 1000

    Agent.update(
      context.fixture,
      &put_in(&1, [:sprites, "workspace-agent", "id"], "replacement-identity")
    )

    replaced = inspect_job(aid, "list", "")
    assert replaced.state == "failed"
    assert replaced.error =~ "replaced Sprite"
    link_workspace(aid)
    assert Fleet.get(aid).sprite_id == "replacement-identity"
    assert is_nil(ManaspritesDesktop.Workspace.latest(aid, "file", "large.txt", false))

    File.write!(
      Path.join(context.root, ".local/share/managoat/config/client.key"),
      "different-service"
    )

    rejected = inspect_job(aid, "list", "")
    assert rejected.state == "failed"
    assert rejected.error =~ "different agent service"
  end

  test "Git inspection does not execute repository external diff or text conversion commands",
       context do
    {aid, project} = workspace_fixture(context)
    link_workspace(aid)
    git(project, ["init", "-q"])
    File.write!(Path.join(project, "README.md"), "before\n")
    File.write!(Path.join(project, ".gitattributes"), "*.md diff=unsafe\n")
    git(project, ["add", "."])

    git(project, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.test",
      "commit",
      "-qm",
      "fixture"
    ])

    marker = Path.join(project, "should-not-run")
    command = "touch " <> marker
    git(project, ["config", "diff.external", command])
    git(project, ["config", "diff.unsafe.textconv", command])
    git(project, ["config", "core.fsmonitor", command])
    git(project, ["config", "core.worktree", context.root])
    File.write!(Path.join(project, "README.md"), "after\n")
    assert inspect_job(aid, "status", "").state == "completed"
    diff = inspect_job(aid, "diff", "README.md")
    assert diff.state == "completed"
    assert diff.result["text"] =~ "+after"
    refute File.exists?(marker)
  end

  test "a pending workspace read does not block real ACP work on the same agent", context do
    {aid, project} = workspace_fixture(context)
    File.write!(Path.join(project, "README.md"), "Project context\n")
    link_workspace(aid)
    Agent.update(context.fixture, &Map.put(&1, :hold_inspection, true))
    {:ok, read} = Fleet.submit(aid, "workspace", %{"action" => "file", "path" => "README.md"})
    assert_receive {:inspection_waiting, socket}, 5000

    {:ok, prompt} =
      Fleet.submit(aid, "prompt", %{"prompt" => "Keep working while I inspect files"})

    assert_receive {:scripted_agent, :wrote, %{"method" => "session/prompt"}}, 5000
    eventually(fn -> assert Repo.get!(Job, prompt.id).state == "completed" end)
    assert Repo.get!(Job, read.id).state == "running"
    send(socket, :release_inspection)
    eventually(fn -> assert Repo.get!(Job, read.id).state == "completed" end)
    assert Repo.get!(Job, read.id).result["text"] == "Project context\n"
  end

  defp workspace_fixture(%{fixture: fixture, root: root}) do
    project = Path.join(root, "project")
    File.mkdir_p!(project)
    config = Path.join(root, ".local/share/managoat/config")
    File.mkdir_p!(config)
    File.write!(Path.join(config, "config.json"), Jason.encode!(%{workspace: project}))
    File.write!(Path.join(config, "client.key"), "synthetic-workspace-key")
    Managoat.Sprite.Store.call({:key, "synthetic-workspace-key"})

    Agent.update(fixture, fn s ->
      put_in(s, [:sprites, "workspace-agent"], %{
        "name" => "workspace-agent",
        "organization" => "test-org",
        "id" => "workspace-identity",
        "url" => s.service_url
      })
    end)

    {:ok, aid} =
      Fleet.attach(
        %{
          "name" => "Workspace agent",
          "organization" => "test-org",
          "url" => Agent.get(fixture, & &1.service_url)
        },
        "synthetic-workspace-key"
      )

    eventually(fn -> assert Fleet.get(aid).status == "ready" end)
    {aid, project}
  end

  defp link_workspace(aid) do
    {:ok, job} =
      Fleet.submit(aid, "workspace", %{
        "action" => "link",
        "path" => "",
        "sprite_name" => "workspace-agent",
        "organization" => "test-org"
      })

    eventually(fn -> assert Repo.get!(Job, job.id).state == "completed" end)
  end

  defp inspect_job(aid, action, path) do
    {:ok, job} = Fleet.submit(aid, "workspace", %{"action" => action, "path" => path})
    eventually(fn -> assert Repo.get!(Job, job.id).state in ~w(completed failed) end)
    Repo.get!(Job, job.id)
  end

  defp git(project, args) do
    {_, 0} = System.cmd("git", ["-C", project | args], stderr_to_stdout: true)
  end

  defp drain_platform_requests do
    receive do
      {:platform_request, _, _} -> drain_platform_requests()
    after
      0 -> :ok
    end
  end

  defp assert_all_proxies_closed do
    receive do
      {:proxy_open, pid, _} ->
        assert_receive {:proxy_closed, ^pid}, 5000
        assert_all_proxies_closed()

      {:proxy_closed, _} ->
        assert_all_proxies_closed()
    after
      250 -> :ok
    end
  end

  defp attrs,
    do: %{
      "name" => "new-agent",
      "organization" => "test-org",
      "display_name" => "New engineer",
      "runtime" => "codex",
      "permissions" => "ask",
      "url_auth" => "public",
      "ref" => "HEAD"
    }

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      receive do
        :changed -> :ok
      after
        25 -> :ok
      end

      eventually(fun, attempts - 1)
  end
end
