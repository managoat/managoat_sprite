defmodule Managoat.Sprite.A2AProcessRuntime do
  @moduledoc false
  alias Managoat.Sprite.{Config, Execution}

  def start(owner) do
    script_path = Path.join(Config.root(), "scripted-options.json")

    script =
      Application.fetch_env!(:managoat_sprite, :script) |> Keyword.delete(:observer) |> Map.new()

    Config.private_write!(script_path, Jason.encode!(script))

    paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&String.contains?(&1, "/_build/"))

    args =
      ["--erl", "+S 2:2"] ++
        Enum.flat_map(paths, &["-pa", &1]) ++
        [
          Path.expand("test/support/a2a_scripted_process.exs"),
          script_path,
          Path.join(Config.root(), "scripted-journal.ndjson")
        ]

    Execution.start(System.find_executable("elixir"), args,
      owner: owner,
      env: [
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

defmodule Managoat.Sprite.A2AHeldStartRuntime do
  @moduledoc false
  alias Managoat.Sprite.A2AProcessRuntime

  def start(owner) do
    result = A2AProcessRuntime.start(owner)
    observer = Application.fetch_env!(:managoat_sprite, :script) |> Keyword.fetch!(:observer)
    send(observer, {:a2a_start_held, self()})

    receive do
      :release_start -> result
    after
      5000 -> result
    end
  end

  defdelegate connect(pid, peer), to: A2AProcessRuntime
  defdelegate write(pid, bytes), to: A2AProcessRuntime
  defdelegate stop(pid), to: A2AProcessRuntime
  defdelegate ready?(), to: A2AProcessRuntime
  defdelegate reconcile(), to: A2AProcessRuntime
end
