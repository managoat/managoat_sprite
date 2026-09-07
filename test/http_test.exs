defmodule Managoat.Sprite.HTTPTest do
  use Managoat.Sprite.TestCase

  test "authenticated create, streamed blocks, durable history, and follow-up resume" do
    assert request(:get, "/api/agents").status == 200
    c = request(:post, "/api/conversations", %{prompt: "hi"})
    assert c.status == 201
    id = decode(c)["data"]["id"]

    eventually(fn ->
      assert decode(request(:get, "/api/conversations/#{id}"))["data"]["status"] == "idle"
    end)

    assert_received {:scripted_agent, :wrote, %{"method" => "session/prompt"}}
    page = decode(request(:get, "/api/conversations/#{id}/events?blocks=true"))

    assert Enum.any?(page["data"], fn e ->
             Enum.any?(e["blocks"], &(&1["kind"] == "text" and &1["body"] == "hello"))
           end)

    stream = request(:get, "/api/conversations/#{id}/stream?blocks=true&wait=false")
    assert stream.status == 200
    assert stream.resp_body =~ "event: output"
    assert request(:post, "/api/conversations/#{id}/prompts", %{prompt: "continue"}).status == 200

    eventually(fn ->
      assert length(decode(request(:get, "/api/conversations/#{id}/turns"))["data"]) == 2
    end)

    eventually(fn ->
      assert_received {:scripted_agent, :wrote, %{"method" => "session/resume"}}
    end)
  end

  test "API keys and CORS preflight" do
    assert conn(:get, "/api/agents") |> HTTP.call(HTTP.init([])) |> Map.get(:status) == 401
    assert conn(:get, "/healthz") |> HTTP.call(HTTP.init([])) |> Map.get(:status) == 200

    c =
      conn(:options, "/api/conversations")
      |> put_req_header("origin", "https://app.example")
      |> HTTP.call(HTTP.init([]))

    assert c.status == 204
    assert get_resp_header(c, "access-control-allow-origin") == ["https://app.example"]

    assert request(:options, "/api/conversations", nil, [{"origin", "https://evil.example"}]).status ==
             403
  end

  test "reject unsupported features and malformed cursors" do
    assert request(:post, "/api/conversations", %{prompt: "hi", images: []}).status == 422
    assert request(:post, "/api/conversations", %{prompt: "hi", agent_id: "other"}).status == 404
    assert request(:post, "/api/conversations", %{prompt: " "}).status == 422
    assert request(:get, "/api/conversations?status[]=running").status == 422
    assert request(:get, "/api/events/stream?streams[]=acp").status == 422

    assert request(:get, "/api/events/stream?wait=false", nil, [{"last-event-id", "bad"}]).status ==
             422
  end

  test "permission waits reserve capacity and only offered options resolve" do
    script = Application.fetch_env!(:managoat_sprite, :script)

    permission = %{
      "toolCall" => %{"title" => "execute", "kind" => "execute"},
      "options" => [
        %{"optionId" => "yes", "kind" => "allow_once", "name" => "Allow"},
        %{"optionId" => "no", "kind" => "reject_once", "name" => "Deny"}
      ]
    }

    Application.put_env(:managoat_sprite, :script, Keyword.put(script, :permission, permission))

    c =
      request(:post, "/api/conversations", %{prompt: "hi", permission_policy: %{default: "ask"}})

    id = decode(c)["data"]["id"]
    eventually(fn -> assert Store.rows("SELECT id FROM permissions") != [] end)
    [[rid]] = Store.rows("SELECT id FROM permissions")
    assert request(:post, "/api/conversations", %{prompt: "another"}).status == 409
    assert request(:post, "/api/conversations/#{id}/prompts", %{prompt: "another"}).status == 400

    assert request(:post, "/api/conversations/#{id}/requests/#{rid}", %{option_id: "invented"}).status ==
             422

    assert request(:post, "/api/conversations/#{id}/requests/#{rid}", %{option_id: "yes"}).status ==
             200

    assert request(:post, "/api/conversations/#{id}/requests/#{rid}", %{option_id: "yes"}).status ==
             409

    eventually(fn -> assert Store.call(:active) == nil end)
  end

  test "idempotent submissions and deleted conversation tombstones preserve workspace", %{
    root: root
  } do
    File.mkdir_p!(Config.get()["workspace"])
    marker = Path.join(Config.get()["workspace"], "keep.txt")
    File.write!(marker, "keep")
    headers = [{"idempotency-key", "request-1"}]
    first = request(:post, "/api/conversations", %{prompt: "hi"}, headers)
    id = decode(first)["data"]["id"]
    retry = request(:post, "/api/conversations", %{prompt: "hi"}, headers)
    assert decode(first) == decode(retry)
    assert request(:post, "/api/conversations", %{prompt: "different"}, headers).status == 409
    eventually(fn -> assert Store.call(:active) == nil end)
    assert request(:delete, "/api/conversations/#{id}").status == 204
    assert request(:post, "/api/conversations", %{prompt: "hi"}, headers).status == 410
    assert File.read!(marker) == "keep"
    assert File.dir?(root)
  end

  test "pagination uses IDs and preserves repeated identical output" do
    {:ok, _, t} = Store.call({:admit, nil, %{"prompt" => "hold"}, nil})
    for _ <- 1..3, do: Store.call({:output, t["conversation_id"], t["id"], "stdout", "same"})
    page = decode(request(:get, "/api/conversations/#{t["conversation_id"]}/events?limit=2"))
    assert page["meta"]["has_more"]
    next = page["meta"]["next_cursor"]

    tail =
      decode(request(:get, "/api/conversations/#{t["conversation_id"]}/events?after=#{next}"))

    assert length(tail["data"]) == 1
  end
end
