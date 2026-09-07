defmodule Managoat.Sprite.RecoveryTest do
  use Managoat.Sprite.TestCase

  defp waiting_conversation do
    script = Application.fetch_env!(:managoat_sprite, :script)

    permission = %{
      "toolCall" => %{"title" => "execute", "kind" => "execute"},
      "options" => [%{"optionId" => "yes", "kind" => "allow_once", "name" => "Allow"}]
    }

    Application.put_env(:managoat_sprite, :script, Keyword.put(script, :permission, permission))

    response =
      request(:post, "/api/conversations", %{prompt: "wait", permission_policy: %{default: "ask"}})

    id = decode(response)["data"]["id"]
    eventually(fn -> assert Store.rows("SELECT id FROM permissions") != [] end)
    id
  end

  test "engine death stops its dependent worker and records uncertain work without replay" do
    id = waiting_conversation()
    assert_received {:scripted_agent, :wrote, %{"method" => "session/prompt"}}
    old = Process.whereis(Engine)
    Process.exit(old, :kill)

    eventually(fn ->
      assert Process.whereis(Engine) != old
      assert Store.call({:get, id})["status"] == "idle"
    end)

    [turn] = Store.call({:turns, id})
    assert turn["status"] == "interrupted"
    assert turn["failure_reason"] == "execution_outcome_unknown"
    refute_received {:scripted_agent, :wrote, %{"method" => "session/prompt"}}
    assert Engine.ready?()
  end

  test "worker death resolves its active slot and pending permission" do
    id = waiting_conversation()
    worker = :sys.get_state(Engine).worker
    Process.exit(worker, :kill)
    eventually(fn -> assert Store.call(:active) == nil end)
    [turn] = Store.call({:turns, id})
    assert turn["status"] == "interrupted"
    [[record]] = Store.rows("SELECT record FROM permissions")
    assert Jason.decode!(record)["status"] == "resolved"
  end

  test "pending admission recovers and dispatch intent never replays" do
    {:ok, _, turn} = Store.call({:admit, nil, %{"prompt" => "recover"}, nil})
    assert turn["status"] == "pending"
    old = Process.whereis(Engine)
    Process.exit(old, :kill)
    eventually(fn -> assert Store.call({:turn, turn["id"]})["status"] == "completed" end)
    assert_received {:scripted_agent, :wrote, %{"method" => "session/prompt"}}
    {:ok, _, ambiguous} = Store.call({:admit, nil, %{"prompt" => "uncertain"}, nil})
    :ok = Store.call({:dispatch, ambiguous["id"], 7})
    Process.exit(Process.whereis(Engine), :kill)
    eventually(fn -> assert Store.call({:turn, ambiguous["id"]})["status"] == "interrupted" end)
    refute_received {:scripted_agent, :wrote, %{"method" => "session/prompt"}}
  end

  test "concurrent admissions reserve exactly one durable slot" do
    results =
      1..20
      |> Task.async_stream(fn n -> Store.call({:admit, nil, %{"prompt" => "#{n}"}, nil}) end)
      |> Enum.to_list()

    assert Enum.count(results, fn {:ok, result} -> match?({:ok, _, _}, result) end) == 1
    assert length(Store.call(:conversations)) == 1
  end

  test "interrupt is cooperative and leaves the conversation resumable" do
    id = waiting_conversation()
    assert request(:post, "/api/conversations/#{id}/interrupt").status == 204
    eventually(fn -> assert Store.call(:active) == nil end)
    assert Store.call({:get, id})["status"] == "idle"
    assert hd(Store.call({:turns, id}))["status"] == "interrupted"
    assert request(:post, "/api/conversations/#{id}/interrupt").status == 409
  end

  test "output budget fails the turn rather than silently truncating history" do
    Application.put_env(:managoat_sprite, :config, Map.put(Config.get(), "max_output_bytes", 1))
    response = request(:post, "/api/conversations", %{prompt: "hi"})
    id = decode(response)["data"]["id"]
    eventually(fn -> assert Store.call(:active) == nil end)
    [turn] = Store.call({:turns, id})
    assert turn["status"] == "failed"
    assert turn["failure_reason"] == "output_budget_exceeded"
  end

  test "unavailable task hold prevents protocol dispatch" do
    c =
      Config.get()
      |> Map.put("task_required", true)
      |> Map.put("task_socket", "/tmp/nonexistent-managoat-socket")

    Application.put_env(:managoat_sprite, :config, c)
    response = request(:post, "/api/conversations", %{prompt: "hi"})
    id = decode(response)["data"]["id"]
    eventually(fn -> assert Store.call(:active) == nil end)
    assert hd(Store.call({:turns, id}))["status"] == "failed"
    refute_received {:scripted_agent, :wrote, %{"method" => "session/prompt"}}
  end
end
