defmodule Managoat.Sprite.Engine do
  @moduledoc "One admission slot, durable recovery, and ownership independent of HTTP clients."
  use GenServer
  alias Managoat.Sprite.{Store, Config, ConversationServer, Lifecycle}
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def admit(id, attrs, key), do: GenServer.call(__MODULE__, {:admit, id, attrs, key}, 30_000)
  def interrupt_task(id), do: GenServer.call(__MODULE__, {:interrupt_task, id})
  def interrupt(id), do: GenServer.call(__MODULE__, {:interrupt, id})
  def answer(id, rid, option), do: GenServer.call(__MODULE__, {:answer, id, rid, option}, 15_000)
  def execution(pid), do: GenServer.call(__MODULE__, {:execution, pid})
  def ready?, do: GenServer.call(__MODULE__, :ready)
  def status, do: GenServer.call(__MODULE__, :status)
  def runtime, do: Application.get_env(:managoat_sprite, :runtime, Managoat.Sprite.Runtime)

  def terminate_conversation(id, delete? \\ false) do
    GenServer.call(__MODULE__, {:close, id, delete?}, 30_000)
  end

  @impl true
  def init(_) do
    Process.send_after(self(), :recover, 10)
    {:ok, %{worker: nil, ref: nil, execution: nil, ready: false, closing: nil}}
  end

  @impl true
  def handle_info(:recover, s) do
    if Process.whereis(Managoat.Sprite.Workers) do
      with :ok <- runtime().reconcile(), :ok <- Lifecycle.reconcile(Store.call(:identity)) do
        recover(s)
      else
        _ ->
          Process.send_after(self(), :recover, 5_000)
          {:noreply, %{s | ready: false}}
      end
    else
      Process.send_after(self(), :recover, 10)
      {:noreply, s}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{ref: ref} = s) do
    result = if s.execution, do: runtime().stop(s.execution), else: :ok
    clean = result in [:ok, {:error, :command_exited}]

    if clean do
      if turn = Store.call(:active) do
        Store.call({:finish, turn["id"], "interrupted", "execution_outcome_unknown", nil})
        Lifecycle.release("managoat-" <> Store.call(:identity) <> "-" <> turn["id"])
      end
    end

    if s.closing do
      {from, id, delete?} = s.closing

      result =
        if clean,
          do: Store.call({if(delete?, do: :delete, else: :terminate), id}),
          else: {:error, {503, "cleanup_unavailable"}}

      GenServer.reply(from, result)
    end

    {:noreply, %{s | worker: nil, ref: nil, execution: nil, closing: nil, ready: clean}}
  end

  @impl true
  def handle_call(:ready, _, s), do: {:reply, s.ready, s}

  def handle_call(:status, _, s) do
    storage = disk_available?()
    busy = not is_nil(s.worker)

    reason =
      cond do
        not s.ready -> "recovery_or_cleanup_pending"
        not storage -> "storage_reserve_exhausted"
        busy -> "turn_active"
        true -> nil
      end

    {:reply,
     %{
       recovery_complete: s.ready,
       storage_available: storage,
       admission_available: s.ready and storage and not busy,
       reason: reason
     }, s}
  end

  def handle_call({:execution, pid}, _, s), do: {:reply, :ok, %{s | execution: pid}}

  def handle_call({:admit, id, attrs, key}, _, s) do
    case Store.call({:replay, id, attrs, key}) do
      :missing ->
        cond do
          not s.ready ->
            {:reply, {:error, {503, "recovering"}}, s}

          s.worker && is_nil(Store.call(:active)) ->
            {:reply, {:error, {503, "cleanup_pending"}}, s}

          true ->
            admit_ready(id, attrs, key, s)
        end

      result ->
        {:reply, result, s}
    end
  end

  def handle_call({:interrupt_task, id}, _, s) do
    case Store.call(:active) do
      %{"id" => ^id} when not is_nil(s.worker) ->
        cancel_worker(id, s, "task_not_cancelable")

      _ ->
        {:reply, {:error, {409, "task_not_cancelable"}}, s}
    end
  end

  def handle_call({:interrupt, id}, _, s) do
    case Store.call(:active) do
      %{"conversation_id" => ^id, "id" => tid} when not is_nil(s.worker) ->
        cancel_worker(tid, s, "no_turn_running")

      _ ->
        {:reply, {:error, {409, "no_turn_running"}}, s}
    end
  end

  def handle_call({:answer, id, rid, option}, _, s) do
    if active?(id, s) and s.closing == nil and Store.call(:active)["cancel_requested"] != true do
      case Store.call({:resolve, id, rid, option}) do
        :ok ->
          send(s.worker, {:answer, rid, option})
          {:reply, :ok, s}

        error ->
          {:reply, error, s}
      end
    else
      {:reply, {:error, {409, "permission_request_resolved"}}, s}
    end
  end

  def handle_call({:close, id, delete?}, from, s) do
    cond do
      s.closing != nil ->
        {:reply, {:error, {409, "cleanup_pending"}}, s}

      active?(id, s) ->
        send(s.worker, :interrupt)
        {:noreply, %{s | closing: {from, id, delete?}}}

      s.worker != nil and is_nil(Store.call(:active)) ->
        {:reply, {:error, {503, "cleanup_pending"}}, s}

      true ->
        {:reply, Store.call({if(delete?, do: :delete, else: :terminate), id}), s}
    end
  end

  defp cancel_worker(tid, s, reason) do
    # The worker can finish while the coordinator is recording cancellation.
    # The Store compare-and-set is authoritative; a lost race is not a crash.
    case Store.call({:cancel_requested, tid}) do
      :ok ->
        send(s.worker, :interrupt)
        {:reply, :ok, s}

      _ ->
        {:reply, {:error, {409, reason}}, s}
    end
  end

  defp recover(s) do
    case Store.call(:active) do
      nil ->
        {:noreply, %{s | ready: true}}

      %{"phase" => "pending"} = turn ->
        {:noreply, start_worker(turn, %{s | ready: true})}

      turn ->
        Store.call({:finish, turn["id"], "interrupted", "execution_outcome_unknown", nil})
        {:noreply, %{s | ready: true}}
    end
  end

  defp admit_ready(id, attrs, key, s) do
    if disk_available?() do
      case Store.call({:admit, id, attrs, key}) do
        {:ok, response, :replayed} -> {:reply, {:ok, response}, s}
        {:ok, response, turn} -> {:reply, {:ok, response}, start_worker(turn, s)}
        error -> {:reply, error, s}
      end
    else
      {:reply, {:error, {503, "storage_reserve_exhausted"}}, s}
    end
  end

  defp active?(id, s) do
    s.worker &&
      case Store.call(:active) do
        %{"conversation_id" => ^id} -> true
        _ -> false
      end
  end

  defp start_worker(t, s) do
    {:ok, pid} = DynamicSupervisor.start_child(Managoat.Sprite.Workers, {ConversationServer, t})
    %{s | worker: pid, ref: Process.monitor(pid), execution: nil}
  end

  defp disk_available? do
    reserve = Config.get()["disk_reserve_bytes"]

    if reserve == 0 do
      true
    else
      case System.cmd("df", ["-Pk", Config.root()], stderr_to_stdout: true) do
        {out, 0} ->
          case out
               |> String.split("\n", trim: true)
               |> List.last()
               |> String.split()
               |> Enum.at(3)
               |> Integer.parse() do
            {kb, _} -> kb * 1024 >= reserve
            _ -> false
          end

        _ ->
          false
      end
    end
  end

  @impl true
  def format_status(status) do
    # OTP crash reports are operational logs, never a copy of a prompt or key.
    Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted})
  end
end
