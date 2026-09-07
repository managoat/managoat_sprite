defmodule Managoat.Sprite.Sandbox.Local do
  @moduledoc "Restricted local provisioning adapter. It never owns the host machine."
  @behaviour Managoat.Sandbox
  alias Managoat.Sandbox.{Handle, Command}
  alias Managoat.Sprite.{Config, Execution, Runtime}
  def provider, do: :local
  def capabilities, do: MapSet.new()
  def build_handle(name), do: %Handle{provider: :local, name: name}
  def create(_, _), do: {:error, :not_supported}
  def get(_), do: {:error, :not_supported}
  def destroy(_), do: {:error, :not_supported}
  def list_all_names, do: {:error, :not_supported}
  def suspend(_), do: {:error, :not_supported}
  def resume(_), do: {:error, :not_supported}
  def list_sessions(_), do: {:error, :not_supported}
  def attach(_, _, _), do: {:error, :not_supported}
  def apply_network_policy(_, _), do: {:error, :not_supported}
  def host_path(_, path), do: remap(path)
  def public_url(_), do: {:error, :not_supported}
  def create_checkpoint(_, _), do: {:error, :not_supported}
  def restore_checkpoint(_, _), do: {:error, :not_supported}

  # The library targets a conventional /home/sprite. This adapter maps that
  # virtual home into application-owned state, including trusted install scripts.
  # User prompts and agent tool arguments never pass through this remapping.
  def remap(path), do: String.replace(path, "/home/sprite", Runtime.home())

  def write_file(_, path, bytes, _opts) do
    path = remap(path)
    Config.private_write!(path, bytes)
    :ok
  rescue
    _ -> {:error, {:write_failed, :local}}
  end

  def spawn(_, cmd, args, opts) do
    cmd = Runtime.resolve(cmd)
    args = Enum.map(args, &remap/1)
    # A login shell rewrites PATH and can select operator-owned runtimes.
    args =
      case args do
        ["-lc", script] -> ["-c", script]
        other -> other
      end

    opts = Keyword.merge([env: Runtime.env(), dir: Config.get()["workspace"]], opts)

    opts =
      Keyword.update!(opts, :env, fn env ->
        Map.merge(Map.new(Runtime.env()), Map.new(env)) |> Map.to_list()
      end)

    case Execution.start(cmd, args, opts) do
      {:ok, pid} -> {:ok, %Command{provider: :local, ref: pid, private: pid}}
      {:error, _} -> {:error, {:unavailable, :spawn_failed}}
    end
  end

  def exec(h, cmd, args, opts) do
    with {:ok, c} <- spawn(h, cmd, args, Keyword.put(opts, :owner, self())) do
      collect(c, [], System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 30_000))
    end
  end

  defp collect(c, chunks, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {stream, %{ref: ref}, data} when ref == c.ref and stream in [:stdout, :stderr] ->
        collect(c, [data | chunks], deadline)

      {:exit, %{ref: ref}, code} when ref == c.ref ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), code}

      {:error, %{ref: ref}, _} when ref == c.ref ->
        {:error, {:unavailable, :process_lost}}
    after
      remaining ->
        stop_command(c)
        {:error, {:unavailable, :timeout}}
    end
  end

  def write_stdin(c, data), do: Execution.write(c.private, data)
  def close_stdin(c), do: Execution.close_stdin(c.private)

  def stop_command(c) do
    case Execution.stop(c.private) do
      :ok -> :ok
      {:error, :command_exited} -> :ok
      _ -> :ok
    end
  end
end
