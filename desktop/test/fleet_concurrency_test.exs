defmodule ManaspritesDesktop.FleetConcurrencyTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias ManaspritesDesktop.{Bootstrap, Fleet}
  alias Managoat.Sprite.Execution
  @endpoint ManaspritesDesktopWeb.Endpoint

  test "two independent Sprite services accept work; one approval wait does not block the other" do
    {:ok, _} = Application.ensure_all_started(:erlexec)
    root = Path.join(System.tmp_dir!(), "manasprites-parallel-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    Application.put_env(:manasprites_desktop, :root, Path.join(root, "desktop"))

    start_supervised!(%{
      id: :desktop,
      start:
        {Supervisor, :start_link,
         [ManaspritesDesktop.Application.children(), [strategy: :rest_for_one]]},
      type: :supervisor
    })

    on_exit(fn -> File.rm_rf!(root) end)
    alpha = service(root, "Alpha")
    beta = service(root, "Beta")
    assert alpha.pid != beta.pid
    assert alpha.port != beta.port
    conn = %{build_conn() | host: "127.0.0.1"} |> get("/launch", %{token: Bootstrap.token()})
    {:ok, view, _} = conn |> recycle() |> live("/")

    for service <- [alpha, beta] do
      view |> element("#agent-nav-#{service.aid}") |> render_click()
      eventually(fn -> assert has_element?(view, "#send:not([disabled])") end)
      view |> form("#composer", %{prompt: "Work on " <> service.name}) |> render_submit()

      eventually(fn ->
        assert has_element?(view, ".permission button[phx-value-option=allow]")
      end)
    end

    assert Fleet.busy?(Fleet.get(alpha.aid))
    assert Fleet.busy?(Fleet.get(beta.aid))

    assert has_element?(view, "#send[disabled]")

    view |> element("#fleet-nav") |> render_click()
    eventually(fn -> assert has_element?(view, "#attention-count", "2") end)

    assert has_element?(
             view,
             "[data-lane='Needs attention'] #agent-card-#{alpha.aid}",
             "Approval requested"
           )

    assert has_element?(
             view,
             "[data-lane='Needs attention'] #agent-card-#{beta.aid}",
             "Approval requested"
           )

    view |> element("#agent-card-#{beta.aid}") |> render_click()

    view |> element(".permission button[phx-value-option=allow]") |> render_click()

    eventually(fn ->
      assert has_element?(view, ".message.assistant", "Beta completed independently")
    end)

    eventually(fn -> refute Fleet.busy?(Fleet.get(beta.aid)) end)
    assert Fleet.busy?(Fleet.get(alpha.aid))
    refute render(view) =~ "Alpha completed independently"
    assert has_element?(view, "#agent-nav-#{alpha.aid}", "Approval requested")
    refute has_element?(view, "#agent-nav-#{beta.aid}", "Approval requested")

    view |> element("#agent-nav-#{alpha.aid}") |> render_click()
    eventually(fn -> assert has_element?(view, "#interrupt") end)
    refute render(view) =~ "Beta completed independently"
    view |> element("#interrupt") |> render_click()
    eventually(fn -> refute Fleet.busy?(Fleet.get(alpha.aid)) end)
    [alpha_conversation] = Fleet.conversations(Fleet.get(alpha.aid))
    [beta_conversation] = Fleet.conversations(Fleet.get(beta.aid))
    assert alpha_conversation["id"] != beta_conversation["id"]
    assert [%{"status" => "interrupted"}] = Fleet.turns(alpha.aid, alpha_conversation["id"])
    assert [%{"status" => "completed"}] = Fleet.turns(beta.aid, beta_conversation["id"])
    view |> element("#fleet-nav") |> render_click()
    eventually(fn -> assert has_element?(view, "#attention-count", "0") end)

    for service <- [alpha, beta] do
      assert :ok = Execution.stop(service.owner)

      eventually(fn ->
        assert {:error, :econnrefused} =
                 :gen_tcp.connect(~c"127.0.0.1", service.port, [:binary, active: false])
      end)
    end
  end

  defp service(root, name) do
    ready = Path.join(root, name <> ".json")
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    args =
      ["--erl", "+S 2:2"] ++
        paths ++
        [Path.expand("support/service_node.exs", __DIR__), Path.join(root, name), ready, name]

    {:ok, owner} =
      Execution.start(System.find_executable("elixir"), args,
        env: [
          {"PATH", System.get_env("PATH")},
          {"HOME", root},
          {"SHELL", "/bin/sh"},
          {"ERL_CRASH_DUMP", "/dev/null"}
        ]
      )

    on_exit(fn -> Execution.stop(owner) end)
    await_service(ready, owner, "", 400)
    %{"port" => port, "pid" => pid} = ready |> File.read!() |> Jason.decode!()

    {:ok, aid} =
      Fleet.attach(%{"name" => name, "url" => "http://127.0.0.1:#{port}"}, "synthetic-" <> name)

    eventually(fn -> assert Fleet.get(aid).status == "ready" end)
    %{name: name, port: port, pid: pid, owner: owner, aid: aid}
  end

  defp eventually(fun, attempts \\ 400)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(25)
      eventually(fun, attempts - 1)
  end

  defp await_service(ready, owner, output, attempts) do
    if File.exists?(ready) do
      :ok
    else
      assert attempts > 0, "Service fixture did not start: #{output}"

      receive do
        {stream, %{ref: ^owner}, data} when stream in [:stdout, :stderr] ->
          await_service(ready, owner, String.slice(output <> data, 0, 4096), attempts - 1)

        {:exit, %{ref: ^owner}, code} ->
          flunk("Service fixture exited #{code}: #{output}")
      after
        25 -> await_service(ready, owner, output, attempts - 1)
      end
    end
  end
end
