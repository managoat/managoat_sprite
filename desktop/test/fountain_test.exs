defmodule ManaspritesDesktop.FountainTest do
  use ExUnit.Case, async: false
  alias ManaspritesDesktop.Fountain
  alias Fountain.{Accounts, Store}
  @key "synthetic-primary-fountain-key-0123456789"
  @other "synthetic-secondary-fountain-key-0123456789"

  setup do
    {:ok, _} = Application.ensure_all_started(:erlexec)
    root = Path.join(System.tmp_dir!(), "manasprites-fountain-#{Store.id()}")
    Application.put_env(:manasprites_desktop, :root, root)
    Application.put_env(:manasprites_desktop, :headless, true)
    Application.put_env(:manasprites_desktop, :fountain_backend, ManaspritesDesktop.FountainLocal)
    Application.put_env(:manasprites_desktop, :fountain_fixture_root, Path.join(root, "services"))
    Application.put_env(:manasprites_desktop, :fountain_fixture_owner, self())

    desktop =
      start_supervised!(%{
        id: :desktop,
        start:
          {Supervisor, :start_link,
           [ManaspritesDesktop.Application.children(), [strategy: :rest_for_one]]},
        type: :supervisor
      })

    start_supervised!(%{
      id: :local_backend,
      start: {Agent, :start_link, [fn -> %{} end, [name: ManaspritesDesktop.FountainLocal]]}
    })

    api = start_supervised!(ManaspritesDesktop.Fountain.Supervisor)
    account = Accounts.import("primary@example.test", @key, %{}, true)
    other = Accounts.import("secondary@example.test", @other, %{}, true)
    server = start_supervised!({Bandit, plug: Fountain.HTTP, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    on_exit(fn ->
      for pid <- [server, api, desktop],
          Process.alive?(pid),
          do: Supervisor.stop(pid, :normal, 15_000)

      for key <- [:headless, :fountain_backend, :fountain_fixture_root, :fountain_fixture_owner],
          do: Application.delete_env(:manasprites_desktop, key)

      File.rm_rf!(root)
    end)

    %{root: root, owner: account["id"], other: other["id"], url: "http://127.0.0.1:#{port}"}
  end

  test "HTTP resource ownership, validation, encrypted values and key revocation", ctx do
    assert request(ctx, :get, "/api/auth/me", nil, "bad").status == 401
    assert request(ctx, :get, "/api/auth/me").body["id"] == ctx.owner

    env =
      request(ctx, :post, "/api/environments", %{
        "name" => "test",
        "env_vars" => %{"EXAMPLE" => "synthetic-private-value"}
      }).body["data"]

    refute Map.has_key?(env, "env_vars")
    refute Jason.encode!(Store.list(ctx.owner, "environment")) =~ "synthetic-private-value"
    assert request(ctx, :get, "/api/environments/#{env["id"]}", nil, @other).status == 404
    assert request(ctx, :put, "/api/environments/#{env["id"]}", %{"name" => ""}).status == 422
    key = request(ctx, :post, "/api/auth/api-keys", %{"name" => "disposable"}).body
    assert request(ctx, :get, "/api/auth/me", nil, key["key"]).status == 200
    assert request(ctx, :delete, "/api/auth/api-keys/#{key["id"]}", nil, @other).status == 404
    assert request(ctx, :delete, "/api/auth/api-keys/#{key["id"]}").status == 204
    assert request(ctx, :get, "/api/auth/me", nil, key["key"]).status == 401
  end

  @tag timeout: 30_000
  test "lost prompt acknowledgement and worker death reuse durable admission", ctx do
    c = conversation(ctx)
    Agent.update(ManaspritesDesktop.FountainLocal, &put_in(&1, [c["id"], :hold_reply], true))
    prompt = file_prompt("11111111-2222-3333-4444-555555555555")

    assert request(ctx, :post, "/api/conversations/#{c["id"]}/prompts", %{"prompt" => prompt}).status ==
             200

    assert_receive {:reply_held, task}, 10_000
    task_ref = Process.monitor(task)
    [{worker, _}] = Registry.lookup(Fountain.Registry, c["id"])
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 5000
    eventually(fn -> assert Store.get(ctx.owner, "conversation", c["id"])["_phase"] == "idle" end)
    completed = Store.get(ctx.owner, "conversation", c["id"])
    assert [turn] = completed["_turns"]
    assert turn["status"] == "completed"

    assert {:ok, %{"data" => [_]}} =
             ManaspritesDesktop.FountainLocal.request(
               ctx.owner,
               completed,
               :get,
               "/api/conversations/#{completed["_remote_id"]}/turns"
             )

    events = Store.events(ctx.owner, c["id"], 0, 1000)
    ids = Enum.map(events, & &1["id"])
    assert ids == Enum.sort(Enum.uniq(ids))
    assert Enum.count(events, &(&1["stage"] == "turn" and &1["state"] == "started")) == 1
    assert request(ctx, :post, "/api/conversations/#{c["id"]}/terminate").status in [204, 503]

    eventually(fn ->
      assert Store.get(ctx.owner, "conversation", c["id"])["status"] == "terminated"
    end)
  end

  @tag timeout: 30_000
  test "concurrent submissions admit one turn and cleanup preserves foreign resources", ctx do
    c = conversation(ctx)
    prompt = file_prompt("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")

    results =
      1..2
      |> Task.async_stream(fn _ -> Fountain.prompt(ctx.owner, c["id"], %{"prompt" => prompt}) end)
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {409, "conversation_busy"}}, &1)) == 1

    assert request(ctx, :post, "/api/conversations/#{c["id"]}/terminate", nil, @other).status ==
             404

    assert request(ctx, :delete, "/api/conversations/#{c["id"]}").status == 409
    eventually(fn -> assert Store.get(ctx.owner, "conversation", c["id"])["_phase"] == "idle" end)
    assert [turn] = Store.get(ctx.owner, "conversation", c["id"])["_turns"]
    assert turn["status"] == "completed"
    assert request(ctx, :post, "/api/conversations/#{c["id"]}/terminate").status in [204, 503]

    eventually(fn ->
      assert Store.get(ctx.owner, "conversation", c["id"])["status"] == "terminated"
    end)

    assert request(ctx, :delete, "/api/conversations/#{c["id"]}").status == 204
  end

  defp conversation(ctx) do
    agent =
      request(ctx, :post, "/api/agents", %{
        "name" => "local",
        "runtime" => "codex",
        "model" => "openai/gpt-5.4"
      }).body["data"]

    response = request(ctx, :post, "/api/conversations", %{"agent_id" => agent["id"]})
    assert response.status == 201
    c = response.body["data"]
    eventually(fn -> assert Store.get(ctx.owner, "conversation", c["id"])["_phase"] == "idle" end)
    c
  end

  defp file_prompt(nonce),
    do:
      "Use a shell tool to write exactly the text #{nonce} followed by one newline into the relative file fountain-suite-local.txt. Read the file."

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(50)
      eventually(fun, attempts - 1)
  end

  test "event cursors survive deletion and encrypted-value corruption fails closed", ctx do
    id = Store.id()
    {:ok, _} = Store.transaction(fn -> Store.stage(ctx.owner, id, "provision", "started") end)
    [event] = Store.events(ctx.owner, id, 0, 100)

    Store.query("DELETE FROM fountain_events WHERE owner=? AND conversation_id=?", [ctx.owner, id])

    {:ok, _} = Store.transaction(fn -> Store.stage(ctx.owner, id, "provision", "done") end)
    [next] = Store.events(ctx.owner, id, event["id"], 100)
    assert next["id"] > event["id"]
    assert {:error, :vault_corrupt} = ManaspritesDesktop.Vault.unseal("invalid", <<1>>)
    {:ok, encrypted} = ManaspritesDesktop.Vault.seal("one", "synthetic")
    assert {:error, :vault_corrupt} = ManaspritesDesktop.Vault.unseal("other", encrypted)
    assert {:ok, "synthetic"} = ManaspritesDesktop.Vault.unseal("one", encrypted)
  end

  @tag :fountain_deployed
  @tag timeout: 180_000
  test "unchanged Fountain deployed profiles over real HTTP, ACP and local subprocesses", ctx do
    checkout = System.get_env("FOUNTAIN_CHECKOUT")

    if checkout do
      cli = Path.join(checkout, "deployed/cli.mjs")
      assert File.regular?(cli)

      for {profile, runtime} <- [
            {"basic", "codex"},
            {"streaming", "codex"},
            {"streaming", "claude"}
          ] do
        config = %{
          "base_url" => ctx.url,
          "credentials" => %{
            "primary" => "FOUNTAIN_SUITE_KEY",
            "secondary" => "FOUNTAIN_SUITE_OTHER_KEY"
          },
          "profiles" => [profile],
          "required_capabilities" => %{
            "runtimes" => ["codex", "claude"],
            "sandbox_providers" => ["sprites"]
          },
          "limits" => %{
            "request_ms" => 10_000,
            "run_ms" => 90_000,
            "cleanup_ms" => 20_000,
            "resources" => 8
          }
        }

        config =
          if profile == "streaming",
            do:
              Map.put(config, "execution", %{
                "runtime" => runtime,
                "model" =>
                  if(runtime == "codex", do: "openai/gpt-5.4", else: "anthropic/claude-haiku-4-5"),
                "sandbox_provider" => "sprites",
                "provision_ms" => 20_000,
                "turn_ms" => 20_000,
                "max_turns" => 2
              }),
            else: config

        path = Path.join(ctx.root, "#{profile}-#{runtime}.json")
        File.write!(path, Jason.encode!(config))
        out = Path.join(ctx.root, "#{profile}-#{runtime}")

        {output, code} =
          System.cmd("node", [cli, "run", "--config", path, "--out", out],
            env: [{"FOUNTAIN_SUITE_KEY", @key}, {"FOUNTAIN_SUITE_OTHER_KEY", @other}],
            stderr_to_stdout: true
          )

        if code != 0 do
          drain_process_errors()
        end

        assert code == 0, output <> "\n" <> File.read!(Path.join(out, "result.json"))
      end
    else
      IO.puts("FOUNTAIN_CHECKOUT unset: external deployed qualification was not run")
    end
  end

  defp drain_process_errors do
    receive do
      {:stderr, _, bytes} ->
        IO.puts(bytes)
        drain_process_errors()

      {:stdout, _, bytes} ->
        IO.puts(bytes)
        drain_process_errors()

      _ ->
        drain_process_errors()
    after
      0 -> :ok
    end
  end

  defp request(ctx, method, path, body \\ nil, key \\ @key) do
    opts = [
      url: ctx.url <> path,
      method: method,
      headers: [{"authorization", "Bearer " <> key}],
      retry: false,
      redirect: false
    ]

    Req.request!(if(body, do: Keyword.put(opts, :json, body), else: opts))
  end
end
