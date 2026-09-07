defmodule Managoat.Sprite.LaunchConfigurationTest do
  use Managoat.Sprite.TestCase

  defp conversation do
    result = request(:post, "/api/conversations", %{prompt: "hello"})
    assert result.status == 201
    id = decode(result)["data"]["id"]

    eventually(fn ->
      assert Store.call(:active) == nil
      assert :sys.get_state(Engine).worker == nil
    end)

    id
  end

  test "retained sessions reject runtime, workspace and instruction changes", %{root: root} do
    id = conversation()
    config = Config.get()
    c = Store.call({:get, id})
    assert [[_]] = Store.rows("SELECT record FROM agents WHERE id=?", [c["configuration_id"]])

    for {key, value} <- [{"runtime", "codex"}, {"workspace", "/another-project"}] do
      Application.put_env(:managoat_sprite, :config, Map.put(config, key, value))
      response = request(:post, "/api/conversations/#{id}/prompts", %{prompt: "continue"})
      assert response.status == 409
      assert decode(response)["error"] == "configuration_changed"
    end

    Application.put_env(:managoat_sprite, :config, config)

    Config.private_write!(
      Path.join(root, "config/instructions.md"),
      "A different agent definition"
    )

    response = request(:post, "/api/conversations/#{id}/prompts", %{prompt: "continue"})
    assert decode(response)["error"] == "configuration_changed"
    assert length(Store.call({:turns, id})) == 1
  end

  test "tightening installation permissions makes a resumed turn ask before answering" do
    id = conversation()

    permission = %{
      "toolCall" => %{"title" => "execute", "kind" => "execute"},
      "options" => [%{"optionId" => "yes", "kind" => "allow_once", "name" => "Allow"}]
    }

    script = Application.fetch_env!(:managoat_sprite, :script)
    Application.put_env(:managoat_sprite, :script, Keyword.put(script, :permission, permission))

    Application.put_env(
      :managoat_sprite,
      :config,
      Map.put(Config.get(), "permissions", %{"default" => "ask"})
    )

    assert request(:post, "/api/conversations/#{id}/prompts", %{prompt: "continue"}).status == 200
    eventually(fn -> assert Store.rows("SELECT id FROM permissions") != [] end)
    turn = List.last(Store.call({:turns, id}))
    assert turn["permission_policy"]["default"] == "ask"
    assert turn["status"] == "running"
    [[rid]] = Store.rows("SELECT id FROM permissions")

    assert request(:post, "/api/conversations/#{id}/requests/#{rid}", %{option_id: "yes"}).status ==
             200

    eventually(fn -> assert Store.call(:active) == nil end)
  end

  test "pending recovery refuses to dispatch under a changed launch definition" do
    {:ok, _, turn} = Store.call({:admit, nil, %{"prompt" => "pending"}, nil})
    Application.put_env(:managoat_sprite, :config, Map.put(Config.get(), "workspace", "/changed"))
    Process.exit(Process.whereis(Engine), :kill)
    eventually(fn -> assert Store.call({:turn, turn["id"]})["status"] == "failed" end)
    assert Store.call({:turn, turn["id"]})["failure_reason"] == "configuration_changed"
    refute_received {:scripted_agent, :wrote, %{"method" => "session/prompt"}}
  end

  test "legacy history without a provable launch definition remains readable" do
    id = conversation()

    Store.query(
      "UPDATE conversations SET record=json_remove(record,'$.configuration_id') WHERE id=?",
      [id]
    )

    assert request(:get, "/api/conversations/#{id}/turns").status == 200
    response = request(:post, "/api/conversations/#{id}/prompts", %{prompt: "continue"})
    assert decode(response)["error"] == "configuration_snapshot_unavailable"
    assert length(Store.call({:turns, id})) == 1
  end

  test "recovered admission records policy tightened before execution" do
    script = Application.fetch_env!(:managoat_sprite, :script)

    permission = %{
      "toolCall" => %{"title" => "execute", "kind" => "execute"},
      "options" => [%{"optionId" => "yes", "kind" => "allow_once", "name" => "Allow"}]
    }

    Application.put_env(:managoat_sprite, :script, Keyword.put(script, :permission, permission))
    {:ok, _, turn} = Store.call({:admit, nil, %{"prompt" => "pending"}, nil})
    assert turn["permission_policy"]["default"] == "auto_allow"

    Application.put_env(
      :managoat_sprite,
      :config,
      Map.put(Config.get(), "permissions", %{"default" => "ask"})
    )

    Process.exit(Process.whereis(Engine), :kill)
    eventually(fn -> assert Store.rows("SELECT id FROM permissions") != [] end)
    assert Store.call({:turn, turn["id"]})["permission_policy"]["default"] == "ask"
    [[rid]] = Store.rows("SELECT id FROM permissions")
    assert Engine.answer(turn["conversation_id"], rid, "yes") == :ok
    eventually(fn -> assert Store.call(:active) == nil end)
  end
end
