defmodule ManaspritesDesktop.FountainLocal do
  @moduledoc false
  alias Managoat.Sprite.Execution
  alias ManaspritesDesktop.ServiceClient

  def provision(_, c) do
    root =
      Path.join(Application.fetch_env!(:manasprites_desktop, :fountain_fixture_root), c["id"])

    File.mkdir_p!(root)
    ready = Path.join(root, "ready.json")
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    args =
      ["--erl", "+S 2:2"] ++
        paths ++ [Path.expand("test/support/fountain_service.exs"), root, ready, c["runtime"]]

    {:ok, pid} =
      Execution.start(System.find_executable("elixir"), args,
        owner: Application.fetch_env!(:manasprites_desktop, :fountain_fixture_owner),
        env: [
          {"SHELL", "/bin/sh"},
          {"PATH", System.get_env("PATH")},
          {"HOME", root},
          {"ERL_CRASH_DUMP", "/dev/null"}
        ]
      )

    Agent.update(__MODULE__, &Map.put(&1, c["id"], %{pid: pid, root: root}))
    await(ready, 200)
    %{"port" => port} = ready |> File.read!() |> Jason.decode!()

    Agent.update(
      __MODULE__,
      &update_in(&1[c["id"]], fn state -> Map.put(state, :url, "http://127.0.0.1:#{port}") end)
    )

    {:ok, %{}}
  end

  defp await(_, 0), do: raise("Local service did not start")

  defp await(path, n) do
    if not File.exists?(path),
      do:
        (
          Process.sleep(50)
          await(path, n - 1)
        )
  end

  def request(_, c, method, path, body \\ nil, key \\ nil) do
    %{url: url} = Agent.get(__MODULE__, & &1[c["id"]])
    result = ServiceClient.request_with_key(url, "synthetic-service-key", method, path, body, key)

    held =
      if method == :post do
        Agent.get_and_update(__MODULE__, fn state ->
          hold = get_in(state, [c["id"], :hold_reply]) == true
          {hold, put_in(state, [c["id"], :hold_reply], false)}
        end)
      else
        false
      end

    if held do
      send(
        Application.fetch_env!(:manasprites_desktop, :fountain_fixture_owner),
        {:reply_held, self()}
      )

      receive do
        :release_reply -> :ok
      end
    end

    result
  end

  def file(_, c, path, max_bytes) do
    %{root: root} = Agent.get(__MODULE__, & &1[c["id"]])
    data = File.read!(Path.join([root, "project", path]))
    bytes = binary_part(data, 0, min(byte_size(data), max_bytes))

    {:ok,
     %{
       "path" => path,
       "content" => Base.encode64(bytes),
       "encoding" => "base64",
       "size" => byte_size(data),
       "truncated" => byte_size(data) > max_bytes
     }}
  end

  def destroy(_, c) do
    case Agent.get(__MODULE__, & &1[c["id"]]) do
      nil ->
        :ok

      %{pid: pid, root: root} ->
        if Process.alive?(pid), do: :ok = Execution.stop(pid)
        File.rm_rf!(root)
        :ok
    end
  end
end

defmodule ManaspritesDesktop.FountainProcessRuntime do
  @moduledoc false
  alias Managoat.Sprite.{Config, Execution}

  def start(owner) do
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    Execution.start(
      System.find_executable("elixir"),
      ["--erl", "+S 2:2"] ++
        paths ++
        [Path.expand("test/support/fountain_acp.exs"), Config.get()["workspace"]],
      owner: owner,
      env: [
        {"SHELL", "/bin/sh"},
        {"PATH", System.get_env("PATH")},
        {"HOME", Config.root()},
        {"ERL_CRASH_DUMP", "/dev/null"}
      ]
    )
  end

  def connect(_, _), do: :ok
  defdelegate write(pid, bytes), to: Execution
  defdelegate stop(pid), to: Execution
  def ready?, do: true
  def reconcile, do: :ok
end
