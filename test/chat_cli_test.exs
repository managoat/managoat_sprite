defmodule Managoat.Sprite.ChatCLITest do
  use Managoat.Sprite.TestCase

  setup %{root: root} do
    server = start_supervised!({Bandit, plug: HTTP, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    config = Path.join(root, "agent.json")
    client_root = Path.join(root, "client")
    prefix = Path.join(root, "cli")

    File.write!(
      config,
      Jason.encode!(%{
        "name" => "test-agent",
        "org" => "test-org",
        "url_auth" => "public",
        "agent" => %{"runtime" => "claude"}
      })
    )

    artifacts = Path.join(root, "cli-release")
    {_, 0} = System.cmd("python3", ["scripts/build-cli.py", "--output", artifacts])

    {_, 0} =
      System.cmd("sh", [Path.join(artifacts, "install-cli.sh"), "--prefix", prefix],
        env: [{"MANASPRITES_ARCHIVE", Path.join(artifacts, "manasprites.tar.gz")}]
      )

    script = """
    import sys
    sys.path.insert(0, 'scripts')
    from provision import load_config, directory, fingerprint, save, private_write
    c = load_config(sys.argv[1])
    root = directory(c)
    save(root / 'state.json', {'config_hash': fingerprint(c)})
    save(root / 'connection.json', {'url': sys.argv[2], 'url_auth': 'public'})
    private_write(root / 'client.key', 'test-secret')
    """

    env = [{"MANASPRITES_ROOT", client_root}]
    {_, 0} = System.cmd("python3", ["-c", script, config, "http://127.0.0.1:#{port}"], env: env)
    %{cli: Path.join(prefix, "bin/manasprites"), config_file: config, env: env}
  end

  test "installed CLI prompts, continues the real ACP session, lists and watches", ctx do
    assert {output, 0} = cli(ctx, ["prompt", "Build something"])
    assert output =~ "Conversation: "
    assert output =~ "hello"
    refute output =~ "test-secret"
    assert_received {:scripted_agent, :wrote, %{"method" => "session/prompt"}}

    [c] = Store.call(:conversations)
    assert {continued, 0} = cli(ctx, ["prompt", "--continue", "Add search"])
    assert length(Regex.scan(~r/hello/, continued)) == 1
    assert_received {:scripted_agent, :wrote, %{"method" => "session/resume"}}
    assert length(Store.call({:turns, c["id"]})) == 2

    assert {listed, 0} = cli(ctx, ["conversations", "--json"])
    assert [%{"id" => id, "status" => "idle"}] = Jason.decode!(listed)["data"]
    assert id == c["id"]
    assert {"hello\n", 0} = cli(ctx, ["watch", id])
    assert length(Store.call({:turns, id})) == 2

    assert {_, 0} = cli(ctx, ["prompt", "--conversation", id, "One more"])
    assert length(Store.call({:turns, id})) == 3
  end

  test "tool activity is rendered alongside text", ctx do
    script = Application.fetch_env!(:managoat_sprite, :script)

    updates =
      [
        %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "tool-1",
          "title" => "Run tests",
          "kind" => "execute"
        },
        %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "tool-1",
          "status" => "completed",
          "content" => [
            %{"type" => "content", "content" => %{"type" => "text", "text" => "tests passed"}}
          ]
        }
      ] ++ script[:updates]

    Application.put_env(:managoat_sprite, :script, Keyword.put(script, :updates, updates))
    assert {output, 0} = cli(ctx, ["prompt", "Run tests"])
    assert output =~ "[tool]"
    assert output =~ "tests passed"
    assert output =~ "hello"
  end

  test "failed turns exit nonzero and empty prompts never dispatch", ctx do
    assert {_, 2} = cli(ctx, ["prompt", "  "])
    assert Store.call(:conversations) == []
    script = Application.fetch_env!(:managoat_sprite, :script)
    Application.put_env(:managoat_sprite, :script, Keyword.put(script, :stop_reason, "cancelled"))
    assert {output, 1} = cli(ctx, ["prompt", "Try this"])
    assert output =~ "turn_failed"
  end

  defp cli(ctx, args) do
    System.cmd(ctx.cli, args ++ ["--file", ctx.config_file], env: ctx.env, stderr_to_stdout: true)
  end
end
