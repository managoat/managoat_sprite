defmodule Managoat.Sprite.ExecutionTest do
  use ExUnit.Case
  alias Managoat.Sprite.Execution

  test "separate streams, real exit status, and total writes after exit" do
    {:ok, p} = Execution.start("/bin/sh", ["-c", "printf out; printf err >&2; exit 7"])
    assert_receive {:stdout, %{ref: ^p}, "out"}, 2000
    assert_receive {:stderr, %{ref: ^p}, "err"}, 2000
    assert_receive {:exit, %{ref: ^p}, 7}, 2000
    assert Execution.write(p, "late") == {:error, :command_exited}
    refute_receive {:exit, %{ref: ^p}, _}
  end

  test "stdin remains open until explicitly closed" do
    {:ok, p} = Execution.start("/bin/cat", [])
    assert :ok = Execution.write(p, "hello\n")
    assert_receive {:stdout, %{ref: ^p}, "hello\n"}, 2000
    assert :ok = Execution.close_stdin(p)
    assert_receive {:exit, %{ref: ^p}, 0}, 2000
  end

  test "owner death stops execution and its process group" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, p} =
          Execution.start("/bin/sh", ["-c", "sleep 120 & wait"], env: [{"PATH", "/usr/bin:/bin"}])

        send(parent, {:started, p})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:started, p}, 2000
    monitor = Process.monitor(p)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^p, :normal}, 5000
  end
end
