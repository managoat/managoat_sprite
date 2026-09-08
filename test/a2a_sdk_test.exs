defmodule Managoat.Sprite.A2ASDKTest do
  use Managoat.Sprite.TestCase

  test "cancel before dispatch prevents a real subprocess prompt and rejects late approval", %{
    root: root
  } do
    Application.put_env(:managoat_sprite, :runtime, Managoat.Sprite.A2AHeldStartRuntime)

    {:ok, result} =
      Engine.admit(
        nil,
        %{"prompt" => "must not dispatch", "a2a_message_id" => "cancel-pending"},
        {:a2a, "cancel-pending"}
      )

    assert_receive {:a2a_start_held, worker}, 5000
    assert :ok = Engine.interrupt_task(result["task_id"])

    assert {:error, {409, "permission_request_resolved"}} =
             Engine.answer(result["context_id"], "late", "yes")

    send(worker, :release_start)

    eventually(
      fn ->
        assert Store.call(:active) == nil
        assert Engine.status().admission_available
      end,
      300
    )

    {task, _} = Store.call({:a2a_snapshot, result["task_id"]})
    assert task["status"]["state"] == "TASK_STATE_CANCELED"
    journal = Path.join(root, "scripted-journal.ndjson")

    frames =
      if File.exists?(journal),
        do: File.read!(journal) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1),
        else: []

    refute Enum.any?(frames, &(&1["method"] == "session/prompt"))
  end

  @tag timeout: 90_000
  test "official A2A SDK executes across real HTTP and ACP subprocess boundaries", %{root: root} do
    python = System.get_env("A2A_TEST_PYTHON") || Path.expand(".venv-a2a/bin/python")

    assert File.exists?(python),
           "Install test/fixtures/a2a/requirements.txt in .venv-a2a or set A2A_TEST_PYTHON"

    config =
      Config.get()
      |> Map.put("permissions", %{"default" => "ask"})
      |> Map.put("a2a", %{
        "enabled" => true,
        "external_origin" => "https://agent.example",
        "origin_verified" => true,
        "ingress" => "public"
      })

    Application.put_env(:managoat_sprite, :config, config)
    Application.put_env(:managoat_sprite, :runtime, Managoat.Sprite.A2AProcessRuntime)
    script = Application.fetch_env!(:managoat_sprite, :script)

    permission = %{
      "toolCall" => %{"title" => "SDK test", "kind" => "execute"},
      "options" => [%{"optionId" => "yes", "name" => "Allow", "kind" => "allow_once"}]
    }

    Application.put_env(:managoat_sprite, :script, Keyword.put(script, :permission, permission))
    server = start_supervised!({Bandit, plug: HTTP, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {out, status} =
      System.cmd(python, ["test/fixtures/a2a/sdk_client.py", "http://127.0.0.1:#{port}"],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ "passed"
    eventually(fn -> assert Engine.status().admission_available end)

    frames =
      Path.join(root, "scripted-journal.ndjson")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.count(frames, &(&1["method"] == "session/prompt")) == 3
    assert Enum.count(frames, &(&1["method"] == "session/resume")) == 2
  end
end
