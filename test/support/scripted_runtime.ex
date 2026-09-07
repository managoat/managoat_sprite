defmodule Managoat.Sprite.TestRuntime do
  alias Managoat.ACP.Testing.ScriptedAgent

  def start(_owner),
    do: ScriptedAgent.start_link(Application.get_env(:managoat_sprite, :script, []))

  def write(pid, bytes), do: ScriptedAgent.writer(pid).(bytes)
  def connect(pid, peer), do: ScriptedAgent.connect(pid, peer)

  def stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    :ok
  end

  def ready?, do: true
  def reconcile, do: :ok
end

defmodule Managoat.Sprite.TestCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Test
      import Plug.Conn
      import Managoat.Sprite.TestCase
      alias Managoat.Sprite.{Store, Engine, HTTP, Config}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "managoat-test-" <> Ecto.UUID.generate())
    System.put_env("MANAGOAT_ROOT", root)

    c =
      Managoat.Sprite.Config.validate!(%{
        "runtime" => "claude",
        "workspace" => Path.join(root, "workspace"),
        "task_required" => false,
        "disk_reserve_bytes" => 0,
        "cors_origins" => ["https://app.example"]
      })

    Application.put_env(:managoat_sprite, :config, c)
    Application.put_env(:managoat_sprite, :runtime, Managoat.Sprite.TestRuntime)

    Application.put_env(:managoat_sprite, :script,
      observer: self(),
      capabilities: %{"sessionCapabilities" => %{"resume" => %{}}},
      updates: [
        %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "hello"}
        }
      ]
    )

    children = Managoat.Sprite.Application.children(c)

    start_supervised!(%{
      id: :test_tree,
      start: {Supervisor, :start_link, [children, [strategy: :rest_for_one]]},
      type: :supervisor
    })

    Managoat.Sprite.Store.call({:key, "test-secret"})
    eventually(fn -> assert Managoat.Sprite.Engine.ready?() end)

    on_exit(fn ->
      File.rm_rf!(root)
      System.delete_env("MANAGOAT_ROOT")
    end)

    %{root: root}
  end

  def request(method, path, body \\ nil, headers \\ []) do
    conn =
      Plug.Test.conn(method, path, if(body, do: Jason.encode!(body), else: ""))
      |> Plug.Conn.put_req_header("authorization", "Bearer test-secret")
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
    Managoat.Sprite.HTTP.call(conn, Managoat.Sprite.HTTP.init([]))
  end

  def decode(conn), do: Jason.decode!(conn.resp_body)
  def eventually(fun, attempts \\ 300)
  def eventually(fun, 0), do: fun.()

  def eventually(fun, n) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(20)
      eventually(fun, n - 1)
  end
end
