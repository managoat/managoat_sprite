defmodule Managoat.Sprite.Engine do
  @moduledoc "One admission slot, durable recovery, and ownership independent of HTTP clients."
  use GenServer
  alias Managoat.Sprite.{Store, Config, ConversationServer}
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def admit(id, attrs, key), do: GenServer.call(__MODULE__, {:admit, id, attrs, key}, 30_000)
  def interrupt(id), do: GenServer.call(__MODULE__, {:interrupt, id})
  def answer(id, rid, option), do: GenServer.call(__MODULE__, {:answer, id, rid, option}, 15_000)
  def execution(pid), do: GenServer.call(__MODULE__, {:execution, pid})
  def ready?, do: GenServer.call(__MODULE__, :ready)
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
      case runtime().reconcile() do
        :ok -> recover(s)
        _ -> {:noreply, %{s | ready: false}}
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
      if turn = Store.call(:active),
        do: Store.call({:finish, turn["id"], "interrupted", "execution_outcome_unknown", nil})
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
  def handle_call({:execution, pid}, _, s), do: {:reply, :ok, %{s | execution: pid}}

  def handle_call({:admit, _, _, _}, _, %{ready: false} = s),
    do: {:reply, {:error, {503, "recovering"}}, s}

  def handle_call({:admit, id, attrs, key}, _, s) do
    if s.worker && is_nil(Store.call(:active)) do
      {:reply, {:error, {503, "cleanup_pending"}}, s}
    else
      admit_ready(id, attrs, key, s)
    end
  end

  def handle_call({:interrupt, id}, _, s) do
    if active?(id, s) do
      send(s.worker, :interrupt)
      {:reply, :ok, s}
    else
      {:reply, {:error, {409, "no_turn_running"}}, s}
    end
  end

  def handle_call({:answer, id, rid, option}, _, s) do
    if active?(id, s) do
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
    if active?(id, s) do
      send(s.worker, :interrupt)
      {:noreply, %{s | closing: {from, id, delete?}}}
    else
      {:reply, Store.call({if(delete?, do: :delete, else: :terminate), id}), s}
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
end
