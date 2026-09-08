defmodule Managoat.Sprite.A2ATest do
  use Managoat.Sprite.TestCase
  alias Managoat.Sprite.A2A.Card

  setup do
    enable()
    :ok
  end

  defp enable(overrides \\ %{}) do
    a2a =
      Map.merge(
        %{
          "enabled" => true,
          "external_origin" => "https://agent.example",
          "origin_verified" => true,
          "ingress" => "public"
        },
        overrides
      )

    Application.put_env(:managoat_sprite, :config, Map.put(Config.get(), "a2a", a2a))
  end

  defp rpc(method, params \\ %{}, headers \\ [{"a2a-version", "1.0"}]) do
    request(
      :post,
      "/a2a",
      %{jsonrpc: "2.0", id: "rpc-1", method: method, params: params},
      headers
    )
    |> decode()
  end

  defp message(id, extra \\ %{}),
    do:
      Map.merge(
        %{"messageId" => id, "role" => "ROLE_USER", "parts" => [%{"text" => "hello"}]},
        extra
      )

  defp send_message(id, extra \\ %{}),
    do: rpc("SendMessage", %{"message" => message(id, extra)})["result"]["task"]

  defp wait_for_approval do
    Application.put_env(
      :managoat_sprite,
      :config,
      Map.put(Config.get(), "permissions", %{"default" => "ask"})
    )

    script = Application.fetch_env!(:managoat_sprite, :script)

    permission = %{
      "toolCall" => %{"title" => "private tool details", "kind" => "execute"},
      "options" => [
        %{"optionId" => "yes", "kind" => "allow_once", "name" => "Allow"},
        %{"optionId" => "no", "kind" => "reject_once", "name" => "Deny"}
      ]
    }

    Application.put_env(:managoat_sprite, :script, Keyword.put(script, :permission, permission))
  end

  defp admitted(id, extra \\ %{}) do
    t =
      rpc("SendMessage", %{
        "message" => message(id, extra),
        "configuration" => %{"returnImmediately" => true}
      })["result"]["task"]

    eventually(fn ->
      assert Store.rows("SELECT id FROM permissions WHERE turn_id=?", [t["id"]]) != []
    end)

    t
  end

  test "sanitized anonymous discovery preserves task authentication, disabled and unverified origins" do
    c =
      conn(:get, "/.well-known/agent-card.json")
      |> Map.put(:host, "attacker.example")
      |> HTTP.call([])

    assert c.status == 200
    card = decode(c)

    assert card["supportedInterfaces"] == [
             %{
               "url" => "https://agent.example/a2a",
               "protocolBinding" => "JSONRPC",
               "protocolVersion" => "1.0"
             }
           ]

    assert card["securityRequirements"] == [%{"schemes" => %{"bearer" => %{"list" => []}}}]
    refute c.resp_body =~ Config.get()["workspace"]
    refute c.resp_body =~ "test-secret"
    refute c.resp_body =~ Config.get()["name"]
    assert conn(:post, "/a2a", "{}") |> HTTP.call([]) |> Map.get(:status) == 401
    assert conn(:get, "/api/capabilities") |> HTTP.call([]) |> Map.get(:status) == 401
    enable(%{"origin_verified" => false})
    assert Card.metadata()["state"] == "configuration_needed"
    assert Card.metadata()["card_url"] == nil
    assert conn(:get, "/.well-known/agent-card.json") |> HTTP.call([]) |> Map.get(:status) == 401
    enable(%{"enabled" => false})
    assert request(:post, "/a2a", %{}).status == 404

    for origin <- [
          "http://agent.example",
          "https://u:p@agent.example",
          "https://agent.example/key?token=x",
          "https://127.0.0.1",
          "https://10.0.0.1",
          "https://localhost",
          "sprite://org/name",
          "https://agent.example/#secret"
        ] do
      refute Card.valid_origin?(origin)
    end
  end

  test "version, JSON-RPC and text-only validation use 1.0 errors" do
    assert rpc("ListTasks", %{}, [])["error"]["code"] == -32009
    assert rpc("ListTasks", %{}, [{"a2a-version", "0.3"}])["error"]["code"] == -32009
    assert rpc("ListTasks", %{}, [{"a2a-version", "1.0.1"}])["result"]["tasks"] == []
    assert rpc("message/send")["error"]["code"] == -32601
    assert rpc("GetTask", %{"id" => "missing"})["error"]["code"] == -32001

    assert rpc("SendMessage", %{"message" => message("invalid", %{"contextId" => "missing"})})[
             "error"
           ]["code"] == -32602

    assert rpc("SendMessage", %{
             "message" =>
               message("invalid", %{"parts" => [%{"url" => "https://private.example"}]})
           })["error"]["code"] == -32005

    assert rpc("SendMessage", %{"message" => message("invalid", %{"role" => "user"})})["error"][
             "code"
           ] == -32602

    assert rpc("SendMessage", %{
             "message" => message("invalid"),
             "configuration" => %{"taskPushNotificationConfig" => %{}}
           })["error"]["code"] == -32003

    for raw <- ["[1]", "null", "{"] do
      r =
        conn(:post, "/a2a", raw)
        |> put_req_header("authorization", "Bearer test-secret")
        |> HTTP.call([])
        |> decode()

      assert r["error"]["code"] in [-32600, -32700]
    end

    assert Store.call(:conversations) == []
  end

  test "blocking tasks, durable deduplication, REST isolation, follow-up and tombstones" do
    t = send_message("one")
    assert t["status"]["state"] == "TASK_STATE_COMPLETED"
    assert [%{"parts" => [%{"text" => "hello"}]}] = t["artifacts"]
    assert length(t["history"]) == 2
    assert_received {:scripted_agent, :wrote, %{"method" => "session/prompt"}}
    assert send_message("one")["id"] == t["id"]
    refute_received {:scripted_agent, :wrote, %{"method" => "session/prompt"}}

    assert rpc("SendMessage", %{
             "message" => message("one", %{"parts" => [%{"text" => "changed"}]})
           })["error"]["code"] == -32602

    next = send_message("two", %{"contextId" => t["contextId"]})
    assert next["id"] != t["id"]
    assert next["contextId"] == t["contextId"]
    assert hd(next["artifacts"])["parts"] == [%{"text" => "hello"}]
    assert_received {:scripted_agent, :wrote, %{"method" => "session/resume"}}

    assert rpc("SendMessage", %{"message" => message("three", %{"taskId" => t["id"]})})["error"][
             "code"
           ] == -32004

    assert rpc("SendMessage", %{
             "message" => message("three", %{"taskId" => t["id"], "contextId" => "wrong"})
           })["error"]["code"] == -32602

    assert rpc("GetTask", %{"id" => t["id"], "historyLength" => 0})["result"]["history"] == []
    page = rpc("ListTasks", %{"contextId" => t["contextId"], "pageSize" => 1})["result"]
    assert page["totalSize"] == 2
    refute Map.has_key?(hd(page["tasks"]), "artifacts")

    page2 =
      rpc("ListTasks", %{
        "contextId" => t["contextId"],
        "pageSize" => 1,
        "pageToken" => page["nextPageToken"]
      })["result"]

    assert page2["nextPageToken"] == ""
    assert hd(page["tasks"])["id"] != hd(page2["tasks"])["id"]
    assert rpc("ListTasks", %{"pageToken" => page["nextPageToken"]})["error"]["code"] == -32602

    rest =
      request(:post, "/api/conversations", %{prompt: "REST"}, [{"idempotency-key", "one"}])
      |> decode()

    eventually(fn -> assert Engine.status().admission_available end)
    assert rpc("ListTasks")["result"]["totalSize"] == 2
    [rest_turn] = Store.call({:turns, rest["data"]["id"]})
    assert rpc("GetTask", %{"id" => rest_turn["id"]})["error"]["code"] == -32001
    assert length(Store.call({:turns, t["contextId"]})) == 2
    assert request(:delete, "/api/conversations/#{t["contextId"]}").status == 204
    assert rpc("SendMessage", %{"message" => message("one")})["error"]["data"]["reason"] == "gone"
  end

  test "simultaneous duplicate deliveries commit one turn and survive a store restart" do
    wait_for_approval()

    results =
      1..12
      |> Task.async_stream(
        fn _ ->
          rpc("SendMessage", %{
            "message" => message("concurrent"),
            "configuration" => %{"returnImmediately" => true}
          })
        end,
        max_concurrency: 12
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &is_map(&1["result"]["task"]))
    ids = Enum.map(results, & &1["result"]["task"]["id"]) |> Enum.uniq()
    assert [id] = ids
    eventually(fn -> assert Store.call(:active)["status"] == "running" end)

    assert rpc("SendMessage", %{
             "message" => message("other"),
             "configuration" => %{"returnImmediately" => true}
           })["error"]["code"] == -32004

    old = Process.whereis(Store)
    Process.exit(old, :kill)

    eventually(fn ->
      assert Process.whereis(Store) != old
      assert Engine.ready?()
      assert rpc("GetTask", %{"id" => id})["result"]["status"]["state"] == "TASK_STATE_FAILED"
    end)

    assert send_message("concurrent")["id"] == id

    assert rpc("ListTasks", %{
             "status" => "TASK_STATE_FAILED",
             "statusTimestampAfter" => "2000-01-01T01:00:00+01:00"
           })["result"]["totalSize"] == 1

    assert rpc("ListTasks", %{"status" => "TASK_STATE_COMPLETED"})["result"]["totalSize"] == 0
    assert Enum.sum(Enum.map(Store.call(:conversations), & &1["turn_count"])) == 1
  end

  test "allow, deny and timeout clear durable owner waits; free text cannot authorize" do
    wait_for_approval()

    for {id, option} <- [{"allow", "yes"}, {"deny", "no"}, {"timeout", nil}] do
      if is_nil(option),
        do:
          Application.put_env(
            :managoat_sprite,
            :config,
            Map.put(Config.get(), "permission_timeout_seconds", 1)
          )

      t = admitted(id)
      snapshot = rpc("GetTask", %{"id" => t["id"]})["result"]
      assert snapshot["status"]["state"] == "TASK_STATE_WORKING"
      assert Jason.encode!(snapshot["status"]) =~ "Waiting for the owner"
      refute Jason.encode!(snapshot) =~ "private tool details"

      assert rpc("SendMessage", %{
               "message" =>
                 message(id <> "-approve", %{
                   "contextId" => t["contextId"],
                   "parts" => [%{"text" => "approve"}]
                 })
             })["error"]["code"] == -32004

      [[rid]] = Store.rows("SELECT id FROM permissions WHERE turn_id=?", [t["id"]])

      if option,
        do:
          assert(
            request(:post, "/api/conversations/#{t["contextId"]}/requests/#{rid}", %{
              option_id: option
            }).status == 200
          )

      eventually(fn -> assert Store.call(:active) == nil end)
      {snapshot, _} = Store.call({:a2a_snapshot, t["id"]})
      refute Jason.encode!(snapshot["status"]) =~ "Waiting for the owner"
      events = Store.call({:events, t["contextId"], 0, 1000, ["permission"]})
      assert Enum.any?(events, &(Jason.decode!(&1["data"])["status"] == "resolved"))
    end
  end

  test "cancel cannot interrupt a newer turn and only returns canceled after cleanup" do
    wait_for_approval()
    t = admitted("cancel")

    assert rpc("CancelTask", %{"id" => t["id"]})["result"]["status"]["state"] ==
             "TASK_STATE_CANCELED"

    assert Store.call(:active) == nil
    next = admitted("next", %{"contextId" => t["contextId"]})
    assert rpc("CancelTask", %{"id" => t["id"]})["error"]["code"] == -32002
    assert Store.call(:active)["id"] == next["id"]

    assert rpc("CancelTask", %{"id" => next["id"]})["result"]["status"]["state"] ==
             "TASK_STATE_CANCELED"
  end

  test "engine restart retains mapping and reports ambiguous dispatch as failure without replay" do
    wait_for_approval()
    t = admitted("restart")
    assert_received {:scripted_agent, :wrote, %{"method" => "session/prompt"}}
    old = Process.whereis(Engine)
    Process.exit(old, :kill)

    eventually(fn ->
      assert Process.whereis(Engine) != old

      assert rpc("GetTask", %{"id" => t["id"]})["result"]["status"]["state"] ==
               "TASK_STATE_FAILED"
    end)

    assert send_message("restart")["id"] == t["id"]
    refute_received {:scripted_agent, :wrote, %{"method" => "session/prompt"}}
    assert Jason.encode!(rpc("GetTask", %{"id" => t["id"]})) =~ "execution_outcome_unknown"
  end

  test "known provider failures stay failed and text projection is bounded on a UTF8 boundary" do
    script = Application.fetch_env!(:managoat_sprite, :script)

    error = %{
      "sessionUpdate" => "session_info_update",
      "_meta" => %{
        "codex" => %{"error" => %{"willRetry" => false, "message" => "private provider failure"}}
      }
    }

    Application.put_env(
      :managoat_sprite,
      :script,
      Keyword.update!(script, :updates, &(&1 ++ [error]))
    )

    t = send_message("provider")
    assert t["status"]["state"] == "TASK_STATE_FAILED"
    refute Jason.encode!(t) =~ "private provider failure"

    {:ok, _, turn} =
      Store.call(
        {:admit, nil, %{"prompt" => "large", "a2a_message_id" => "large"}, {:a2a, "large"}}
      )

    update =
      Jason.encode!(%{
        jsonrpc: "2.0",
        method: "session/update",
        params: %{
          update: %{
            sessionUpdate: "agent_message_chunk",
            content: %{type: "text", text: String.duplicate("é", 524_300)}
          }
        }
      })

    Store.call({:output, turn["conversation_id"], turn["id"], "acp", update})
    {task, _} = Store.call({:a2a_snapshot, turn["id"]})

    assert task["metadata"]["textTruncated"],
           inspect(
             Store.rows("SELECT length(text),truncated FROM a2a_tasks WHERE id=?", [turn["id"]])
           )

    text = hd(hd(task["artifacts"])["parts"])["text"]
    assert byte_size(text) == 1_048_576
    assert String.valid?(text)
  end
end
