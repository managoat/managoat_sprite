defmodule ManaspritesDesktop.FleetTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias ManaspritesDesktop.{Agent, Bootstrap, Fleet, Job, Repo, Vault}
  @endpoint ManaspritesDesktopWeb.Endpoint

  setup do
    root = Path.join(System.tmp_dir!(), "manasprites-fleet-#{Ecto.UUID.generate()}")
    Application.put_env(:manasprites_desktop, :root, Path.join(root, "desktop"))

    desktop_supervisor =
      start_supervised!(%{
        id: :desktop,
        start:
          {Supervisor, :start_link,
           [ManaspritesDesktop.Application.children(), [strategy: :rest_for_one]]},
        type: :supervisor
      })

    Phoenix.PubSub.subscribe(ManaspritesDesktop.PubSub, "fleet")

    System.put_env("MANAGOAT_ROOT", Path.join(root, "sprite"))

    config =
      Managoat.Sprite.Config.validate!(%{
        "runtime" => "claude",
        "workspace" => Path.join(root, "project"),
        "task_required" => false,
        "disk_reserve_bytes" => 0
      })

    Application.put_env(:managoat_sprite, :config, config)

    Application.put_env(:managoat_sprite, Managoat.Sprite.Repo,
      pool_size: 1,
      journal_mode: :wal,
      synchronous: :full,
      busy_timeout: 5000,
      foreign_keys: :on
    )

    Application.put_env(:managoat_sprite, :runtime, ManaspritesDesktop.ServiceFixture)

    Application.put_env(:managoat_sprite, :script,
      observer: self(),
      capabilities: %{"sessionCapabilities" => %{"resume" => %{}}},
      updates: [
        %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "Desktop agent response"}
        }
      ]
    )

    sprite_supervisor =
      start_supervised!(%{
        id: :sprite,
        start:
          {Supervisor, :start_link,
           [Managoat.Sprite.Application.children(config), [strategy: :rest_for_one]]},
        type: :supervisor
      })

    Managoat.Sprite.Store.call({:key, "synthetic-service-key"})
    eventually(fn -> assert Managoat.Sprite.Engine.ready?() end)

    server =
      start_supervised!(
        {Bandit, plug: {ManaspritesDesktop.ObservedService, self()}, port: 0, ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    on_exit(fn ->
      # Stop writers before removing their SQLite roots. An on_exit callback
      # can run while the test supervisor still owns its children.
      for pid <- [server, sprite_supervisor, desktop_supervisor] do
        if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 15_000)
      end

      remove_fixture(root, 20)
      System.delete_env("MANAGOAT_ROOT")
    end)

    %{root: root, url: "http://127.0.0.1:#{port}"}
  end

  test "credential settings persist encrypted values without rendering them", %{root: root} do
    {:ok, view, _} = live_session()
    view |> element("#settings-open") |> render_click()

    view
    |> form("#credential-form", %{provider: "openai", secret: "synthetic-inference-secret"})
    |> render_submit()

    assert has_element?(view, "#credential-openai", "Saved")
    assert {:ok, "synthetic-inference-secret"} = Vault.get("openai")
    refute render(view) =~ "synthetic-inference-secret"

    for file <- Path.wildcard(Path.join(root, "desktop/fleet.sqlite3*")) do
      refute File.read!(file) =~ "synthetic-inference-secret"
    end

    assert File.stat!(Path.join(root, "desktop/vault.key")).mode |> Bitwise.band(0o777) == 0o600
    view |> element("#credential-openai button") |> render_click()
    assert {:error, :credential_missing} = Vault.get("openai")
  end

  test "LiveView connects, prompts and continues the real ACP session", %{url: url} do
    {:ok, view, _} = live_session()
    view |> element("#connect-open") |> render_click()

    view
    |> element("#connect-form select[name=transport]")
    |> render_change(%{"transport" => "private"})

    assert has_element?(view, "#connect-form input[name=sprite_name][required]")
    refute has_element?(view, "#connect-form input[name=url]")

    view
    |> element("#connect-form select[name=transport]")
    |> render_change(%{"transport" => "direct"})

    assert has_element?(view, "#connect-form input[name=url][required]")
    refute has_element?(view, "#connect-form input[name=sprite_name]")

    view
    |> form("#connect-form", %{
      name: "Workspace engineer",
      organization: "test-org",
      url: url,
      secret: "synthetic-service-key"
    })
    |> render_submit()

    eventually(fn -> assert [%Agent{runtime: "claude", status: "ready"}] = Fleet.list() end)
    [agent] = Fleet.list()
    eventually(fn -> assert has_element?(view, "#send:not([disabled])") end)
    view |> form("#composer", %{prompt: "Build something useful"}) |> render_submit()
    assert_receive {:scripted_agent, :wrote, %{"method" => "session/prompt"}}, 5000

    eventually(fn ->
      assert has_element?(view, ".message.assistant", "Desktop agent response")
    end)

    eventually(fn -> assert has_element?(view, "#send:not([disabled])") end)
    view |> form("#composer", %{prompt: "Continue that work"}) |> render_submit()
    assert_receive {:scripted_agent, :wrote, %{"method" => "session/resume"}}, 5000

    eventually(fn ->
      assert [c] = Fleet.conversations(Fleet.get(agent.id))
      assert length(Fleet.turns(agent.id, c["id"])) == 2
      assert Enum.all?(Fleet.turns(agent.id, c["id"]), &(&1["status"] == "completed"))
    end)

    refute render(view) =~ "synthetic-service-key"
    assert [%{"status" => "idle"}] = Managoat.Sprite.Store.call(:conversations)
  end

  test "provider billing reports survive output pagination without rewriting service completion",
       %{url: url} do
    script = Application.fetch_env!(:managoat_sprite, :script)

    diagnostic = %{
      "sessionUpdate" => "session_info_update",
      "_meta" => %{
        "codex" => %{
          "error" => %{
            "message" => "Please add credits. synthetic-private-provider-detail",
            "willRetry" => true
          }
        }
      }
    }

    text = %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => "Output "}
    }

    Application.put_env(
      :managoat_sprite,
      :script,
      Keyword.put(script, :updates, [diagnostic | List.duplicate(text, 2005)])
    )

    aid = attach(url)
    {:ok, view, _} = live_session()
    view |> element("#agent-nav-#{aid}") |> render_click()
    view |> form("#composer", %{prompt: "Exercise provider billing failure"}) |> render_submit()
    assert_receive {:scripted_agent, :wrote, %{"method" => "session/prompt"}}, 5000

    eventually(fn ->
      assert [conversation] = Fleet.conversations(Fleet.get(aid))
      assert [turn] = Fleet.turns(aid, conversation["id"])
      assert turn["status"] == "completed"
      assert turn["desktop_warning"] =~ "billing or credit error"
      assert has_element?(view, ".provider-warning", "billing or credit error")
      assert has_element?(view, ".stage", "Review provider error (service: completed)")
      assert has_element?(view, "#agent-nav-#{aid}", "Review provider error")
    end)

    # Only a fixed warning is rendered; protocol diagnostics may carry private data.
    refute render(view) =~ "synthetic-private-provider-detail"
    view |> element("#fleet-nav") |> render_click()
    assert has_element?(view, "[data-lane='Needs attention'] #agent-card-#{aid}")
    assert has_element?(view, "#attention-count", "1")
    view |> element("#agent-nav-#{aid}") |> render_click()
    assert has_element?(view, ".provider-warning", "billing or credit error")

    transient =
      put_in(diagnostic, ["_meta", "codex", "error", "message"], "Transient stream disconnect")

    ordinary =
      put_in(
        text,
        ["content", "text"],
        "Documentation mentions add credits; this is ordinary output."
      )

    Application.put_env(
      :managoat_sprite,
      :script,
      Keyword.put(script, :updates, [transient, ordinary])
    )

    view |> form("#composer", %{prompt: "Continue successfully"}) |> render_submit()
    assert_receive {:scripted_agent, :wrote, %{"method" => "session/resume"}}, 5000

    eventually(fn ->
      [conversation] = Fleet.conversations(Fleet.get(aid))
      assert [first, second] = Fleet.turns(aid, conversation["id"])
      assert first["desktop_warning"]
      assert second["status"] == "completed"
      refute second["desktop_warning"]
      refute Fleet.provider_warning?(Fleet.get(aid))
      refute has_element?(view, "#agent-nav-#{aid}", "Review provider error")
      assert has_element?(view, ".provider-warning", "billing or credit error")
    end)

    terminal = put_in(transient, ["_meta", "codex", "error", "willRetry"], false)
    Application.put_env(:managoat_sprite, :script, Keyword.put(script, :updates, [terminal]))
    view |> form("#composer", %{prompt: "Exercise a terminal provider error"}) |> render_submit()

    eventually(fn ->
      [conversation] = Fleet.conversations(Fleet.get(aid))
      assert [_, _, third] = Fleet.turns(aid, conversation["id"])
      assert third["status"] == "completed"
      assert third["desktop_warning"] =~ "without an automatic retry"
      assert has_element?(view, ".provider-warning", "without an automatic retry")
    end)
  end

  test "permission decisions and interruption execute against the real service", %{url: url} do
    script = Application.fetch_env!(:managoat_sprite, :script)

    permission = %{
      "toolCall" => %{"toolCallId" => "tool-1", "title" => "Edit file", "kind" => "edit"},
      "options" => [
        %{"optionId" => "allow", "name" => "Allow once", "kind" => "allow_once"},
        %{"optionId" => "deny", "name" => "Deny", "kind" => "reject_once"}
      ]
    }

    Application.put_env(:managoat_sprite, :script, Keyword.put(script, :permission, permission))
    config = Application.fetch_env!(:managoat_sprite, :config)

    Application.put_env(
      :managoat_sprite,
      :config,
      Map.put(config, "permissions", %{"default" => "ask"})
    )

    aid = attach(url)
    {:ok, view, _} = live_session()
    view |> element("#agent-nav-#{aid}") |> render_click()
    view |> form("#composer", %{prompt: "Edit the file"}) |> render_submit()

    eventually(fn ->
      assert [c] = Fleet.conversations(Fleet.get(aid))

      assert Enum.any?(Fleet.events(aid, c["id"]), fn e ->
               Enum.any?(e["blocks"] || [], &(&1["kind"] == "permission_request"))
             end)
    end)

    [c] = Fleet.conversations(Fleet.get(aid))

    eventually(fn -> assert has_element?(view, ".permission button[phx-value-option=allow]") end)
    view |> element(".permission button[phx-value-option=allow]") |> render_click()

    assert_receive {:scripted_agent, :permission_answered, %{"optionId" => "allow"}}, 5000

    eventually(fn ->
      assert Enum.any?(Fleet.jobs(aid), &(&1.kind == "permission" and &1.state == "completed"))
    end)

    eventually(fn -> refute Fleet.busy?(Fleet.get(aid)) end)

    {:ok, _} =
      Fleet.submit(aid, "prompt", %{"prompt" => "Another edit", "conversation_id" => c["id"]})

    assert_receive {:scripted_agent, :wrote, %{"method" => "session/prompt"}}, 5000
    eventually(fn -> assert length(Managoat.Sprite.Store.call({:turns, c["id"]})) == 2 end)
    {:ok, stopped} = Fleet.submit(aid, "interrupt", %{"conversation_id" => c["id"]})
    eventually(fn -> assert Repo.get!(Job, stopped.id).state == "completed" end)
    eventually(fn -> refute Fleet.busy?(Fleet.get(aid)) end)
  end

  test "an accepted prompt with a lost acknowledgement is never automatically replayed", %{url: _} do
    server =
      start_supervised!(
        {Bandit,
         plug: {ManaspritesDesktop.HeldAcknowledgement, self()}, port: 0, ip: {127, 0, 0, 1}},
        id: :held_server
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    aid = attach("http://127.0.0.1:#{port}")
    {:ok, job} = Fleet.submit(aid, "prompt", %{"prompt" => "Accept only once"})
    assert_receive {:accepted_without_ack, response_owner}, 5000
    [{pid, _}] = Registry.lookup(ManaspritesDesktop.Connections, aid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    send(response_owner, :release_ack)
    eventually(fn -> assert Repo.get!(Job, job.id).state == "unknown" end)

    assert {:error, :submission_pending} =
             Fleet.submit(aid, "prompt", %{"prompt" => "Would duplicate work"})

    assert_receive {:scripted_agent, :wrote, %{"method" => "session/prompt"}}, 5000
    {:ok, sync} = Fleet.submit(aid, "sync", %{})
    eventually(fn -> assert Repo.get!(Job, sync.id).state == "completed" end)
    assert [%{"status" => "idle"}] = Fleet.conversations(Fleet.get(aid))
    # Routine refreshes must not hide the only control that can clear the hold.
    for _ <- 1..21 do
      {:ok, refresh} = Fleet.submit(aid, "sync", %{})
      eventually(fn -> assert Repo.get!(Job, refresh.id).state == "completed" end)
    end

    assert Enum.any?(Fleet.jobs(aid), &(&1.id == job.id and &1.state == "unknown"))
    assert Fleet.prompt_pending?(aid)
    refute_receive {:scripted_agent, :wrote, %{"method" => "session/prompt"}}, 300
    assert :ok = Fleet.resolve_unknown(aid, job.id)
    assert Repo.get!(Job, job.id).state == "reviewed"
  end

  test "an acknowledged approval clears its marker while the actual ACP turn is still running", %{
    url: url
  } do
    script = Application.fetch_env!(:managoat_sprite, :script)

    permission = %{
      "toolCall" => %{"toolCallId" => "tool-1", "title" => "Edit file", "kind" => "edit"},
      "options" => [%{"optionId" => "allow", "name" => "Allow once", "kind" => "allow_once"}]
    }

    Application.put_env(:managoat_sprite, :runtime, ManaspritesDesktop.HeldPermissionRuntime)
    Application.put_env(:managoat_sprite, :script, Keyword.put(script, :permission, permission))
    config = Application.fetch_env!(:managoat_sprite, :config)

    Application.put_env(
      :managoat_sprite,
      :config,
      Map.put(config, "permissions", %{"default" => "ask"})
    )

    aid = attach(url)
    {:ok, view, _} = live_session()
    view |> element("#agent-nav-#{aid}") |> render_click()
    view |> form("#composer", %{prompt: "Wait for my approval"}) |> render_submit()
    eventually(fn -> assert has_element?(view, ".permission button[phx-value-option=allow]") end)
    assert Fleet.approval_requested?(Fleet.get(aid))
    view |> element(".permission button[phx-value-option=allow]") |> render_click()
    assert_receive {:permission_write_held, peer}, 5000
    eventually(fn -> assert has_element?(view, ".permission", "Answer acknowledged") end)
    assert Fleet.busy?(Fleet.get(aid))
    refute Fleet.approval_requested?(Fleet.get(aid))
    assert has_element?(view, ".permission button[disabled]")
    send(peer, :release_permission)
    assert_receive {:scripted_agent, :permission_answered, _}, 5000
    eventually(fn -> refute Fleet.busy?(Fleet.get(aid)) end)
  end

  test "bad authentication is visible and a corrected key reconnects", %{url: url} do
    {:ok, aid} = Fleet.attach(%{"name" => "Agent", "url" => url}, "invalid-key")
    eventually(fn -> assert Fleet.get(aid).status == "attention" end)
    assert Fleet.get(aid).error =~ "rejected"
    {:ok, _} = Fleet.update_key(aid, "synthetic-service-key")
    eventually(fn -> assert Fleet.get(aid).status == "ready" end)
    assert :ok = Fleet.remove(aid)
    assert Fleet.list() == []
    assert {:error, :credential_missing} = Vault.get("agent:" <> aid)
    assert Managoat.Sprite.Engine.ready?()
  end

  test "credentials and conversation cache survive a full desktop restart without idle requests",
       %{url: url} do
    aid = attach(url)
    {:ok, job} = Fleet.submit(aid, "prompt", %{"prompt" => "Remember this work"})
    eventually(fn -> assert Repo.get!(Job, job.id).state == "completed" end)
    cid = Repo.get!(Job, job.id).result["conversation_id"]
    eventually(fn -> assert [%{"status" => "completed"}] = Fleet.turns(aid, cid) end)
    assert :ok = Vault.put("sprites", "synthetic-platform-key")
    Phoenix.PubSub.unsubscribe(ManaspritesDesktop.PubSub, "fleet")
    assert :ok = stop_supervised(:desktop)

    # This test process outlives the app and can retain unreachable Ecto query
    # handles. Release their SQLite NIF resources before reopening the database;
    # a real native relaunch uses a new BEAM process instead.
    :erlang.garbage_collect()

    start_supervised!(%{
      id: :desktop,
      start:
        {Supervisor, :start_link,
         [ManaspritesDesktop.Application.children(), [strategy: :rest_for_one]]},
      type: :supervisor
    })

    assert Fleet.get(aid).status == "disconnected"
    Phoenix.PubSub.subscribe(ManaspritesDesktop.PubSub, "fleet")
    assert {:ok, "synthetic-platform-key"} = Vault.get("sprites")
    assert {:ok, "synthetic-service-key"} = Vault.get("agent:" <> aid)
    assert [%{"prompt" => "Remember this work", "status" => "completed"}] = Fleet.turns(aid, cid)

    assert Enum.any?(
             Fleet.events(aid, cid),
             &String.contains?(Jason.encode!(&1), "Desktop agent response")
           )

    drain_requests()
    refute_receive {:service_request, _, _}, 1000
    {:ok, sync} = Fleet.submit(aid, "sync", %{"conversation_id" => cid})
    eventually(fn -> assert Repo.get!(Job, sync.id).state == "completed" end)
    drain_requests()
    refute_receive {:service_request, _, _}, 1000
  end

  defp drain_requests do
    receive do
      {:service_request, _, _} -> drain_requests()
    after
      0 -> :ok
    end
  end

  defp remove_fixture(root, attempts) do
    # Exqlite closes with sqlite3_close_v2: statement destructors can finish
    # WAL/SHM cleanup after the owning OTP processes have stopped. Retry only
    # a directory changing during removal, with a bounded deadline.
    case File.rm_rf(root) do
      {:ok, _} ->
        :ok

      {:error, reason, _} when reason in [:eexist, :enotempty] and attempts > 0 ->
        Process.sleep(25)
        remove_fixture(root, attempts - 1)

      {:error, reason, path} ->
        raise File.Error, reason: reason, action: "remove fixture", path: path
    end
  end

  defp attach(url) do
    {:ok, aid} = Fleet.attach(%{"name" => "Fixture agent", "url" => url}, "synthetic-service-key")
    eventually(fn -> assert Fleet.get(aid).status == "ready" end)
    aid
  end

  defp live_session do
    conn = %{build_conn() | host: "127.0.0.1"} |> get("/launch", %{token: Bootstrap.token()})
    conn |> recycle() |> live("/")
  end

  defp eventually(fun, tries \\ 120)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, tries) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      receive do
        :changed -> :ok
      after
        50 -> :ok
      end

      eventually(fun, tries - 1)
  end
end
