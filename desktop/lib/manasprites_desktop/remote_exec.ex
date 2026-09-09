defmodule ManaspritesDesktop.RemoteExec do
  @moduledoc "Bounded SDK exec with ownership cleanup and stdin-only secret transport."
  @external_resource Path.expand("../../../scripts/provision_remote.py", __DIR__)
  @setup File.read!(@external_resource)
  @loader "import base64,io,json,sys; p=json.load(sys.stdin); s=base64.b64decode(p.pop('source')); sys.stdin=io.StringIO(json.dumps(p)); exec(compile(s,'<manasprites-setup>','exec'))"

  def setup(token, name, payload) do
    script(token, name, @setup, payload, 1_260_000)
  end

  def script(token, name, source, payload, timeout \\ 30_000) do
    run(
      token,
      name,
      "python3",
      ["-c", @loader],
      Jason.encode!(Map.put(payload, "source", Base.encode64(source))),
      timeout
    )
  end

  def run(token, name, executable, args, input, timeout \\ 30_000) do
    owner = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        owner_ref = Process.monitor(owner)
        result = execute(owner_ref, token, name, executable, args, input, timeout)
        send(owner, {ref, result})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _} ->
        {:error, :remote_unavailable}
    after
      timeout + 25_000 ->
        send(pid, :cancel)
        Process.demonitor(monitor, [:flush])
        {:error, :remote_unavailable}
    end
  end

  defp execute(owner_ref, token, name, executable, args, input, timeout) do
    # The SDK command does not monitor its owner. This guardian keeps ownership
    # through connection setup and closes the socket when the OTP job disappears.
    client = Sprites.new(token, base_url: ManaspritesDesktop.PlatformClient.base_url())

    case Sprites.spawn(Sprites.sprite(client, name), executable, args, stdin: true) do
      {:ok, command} ->
        try do
          :ok = Sprites.write(command, input)
          :ok = Sprites.close_stdin(command)
          collect(command.ref, owner_ref, "", 0, System.monotonic_time(:millisecond) + timeout)
        after
          if Process.alive?(command.pid), do: stop(command.pid)
        end

      _ ->
        {:error, :remote_unavailable}
    end
  rescue
    _ -> {:error, :remote_unavailable}
  catch
    :exit, _ -> {:error, :remote_unavailable}
  end

  defp collect(_, _, _, bytes, _) when bytes > 1_048_576, do: {:error, :remote_unavailable}

  defp collect(ref, owner_ref, output, bytes, deadline) do
    receive do
      {:stdout, %{ref: ^ref}, data} ->
        collect(ref, owner_ref, output <> data, bytes + byte_size(data), deadline)

      {:stderr, %{ref: ^ref}, data} ->
        collect(ref, owner_ref, output, bytes + byte_size(data), deadline)

      {:exit, %{ref: ^ref}, 0} ->
        case Jason.decode(output) do
          {:ok, value} when is_map(value) -> {:ok, value}
          _ -> {:error, :remote_unavailable}
        end

      {:DOWN, ^owner_ref, :process, _, _} ->
        {:error, :remote_unavailable}

      :cancel ->
        {:error, :remote_unavailable}

      {:exit, %{ref: ^ref}, _} ->
        {:error, :remote_unavailable}

      {:error, %{ref: ^ref}, _} ->
        {:error, :remote_unavailable}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> {:error, :remote_unavailable}
    end
  end

  defp stop(pid) do
    GenServer.stop(pid, :normal, 5000)
  catch
    :exit, _ -> :ok
  end
end
