defmodule Managoat.Sprite.Execution do
  @moduledoc "Owned local processes with separate byte streams and process-group cleanup through erlexec."
  use GenServer

  def start(command, args, opts \\ []) do
    GenServer.start(__MODULE__, {command, args, Keyword.put_new(opts, :owner, self())})
  end

  def write(pid, data), do: safe_call(pid, {:stdin, IO.iodata_to_binary(data)})
  def close_stdin(pid), do: safe_call(pid, {:stdin, :eof})
  def stop(pid), do: safe_call(pid, :stop)

  def safe_call(pid, message) do
    GenServer.call(pid, message, 15_000)
  catch
    :exit, {:noproc, _} -> {:error, :command_exited}
    :exit, {:normal, _} -> {:error, :command_exited}
    :exit, _ -> {:error, :execution_unavailable}
  end

  @impl true
  def init({cmd, args, opts}) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)

    base = [
      :stdin,
      :stdout,
      :stderr,
      :monitor,
      :kill_group,
      {:group, 0},
      {:kill_timeout, 2},
      {:env, [:clear | Keyword.get(opts, :env, [])]}
    ]

    base = if opts[:dir], do: [{:cd, opts[:dir]} | base], else: base

    case :exec.run_link([cmd | args], base) do
      {:ok, pid, os_pid} ->
        {:ok,
         %{pid: pid, os_pid: os_pid, owner: owner, monitor: Process.monitor(owner), stop: []}}

      {:error, _} ->
        {:stop, :spawn_failed}
    end
  end

  @impl true
  def handle_call({:stdin, data}, _, s), do: {:reply, :exec.send(s.os_pid, data), s}

  def handle_call(:stop, from, s) do
    :exec.stop(s.os_pid)
    {:noreply, %{s | stop: [from | s.stop]}}
  end

  @impl true
  def handle_info({stream, os_pid, data}, %{os_pid: os_pid} = s)
      when stream in [:stdout, :stderr] do
    send(s.owner, {stream, %{ref: self()}, data})
    {:noreply, s}
  end

  def handle_info({:DOWN, os_pid, :process, _, reason}, %{os_pid: os_pid} = s) do
    terminal =
      case reason do
        :normal ->
          {:exit, 0}

        {:exit_status, status} ->
          case :exec.status(status) do
            {:status, code} -> {:exit, code}
            {:signal, signal, _} -> {:exit, 128 + :exec.signal_to_int(signal)}
            _ -> {:error, :process_lost}
          end

        _ ->
          {:error, :process_lost}
      end

    {kind, value} = terminal
    send(s.owner, {kind, %{ref: self()}, value})
    Enum.each(s.stop, &GenServer.reply(&1, :ok))
    {:stop, :normal, s}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = s) do
    :exec.stop(s.os_pid)
    {:noreply, s}
  end

  def handle_info({:EXIT, pid, reason}, %{pid: pid} = s),
    do: handle_info({:DOWN, s.os_pid, :process, pid, reason}, s)

  def handle_info({:EXIT, _, _}, s), do: {:noreply, s}
  @impl true
  def format_status(status) do
    # OTP crash reports are operational logs, never a copy of a prompt or key.
    Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted})
  end
end
