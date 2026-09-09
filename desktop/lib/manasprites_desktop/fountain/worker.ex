defmodule ManaspritesDesktop.Fountain.Worker do
  @moduledoc "Durable host admission with independent remote execution and replay."
  use GenServer
  alias ManaspritesDesktop.Fountain
  alias ManaspritesDesktop.Fountain.Store

  def child_spec(arg),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :transient}

  def start_link({owner, id}), do: GenServer.start_link(__MODULE__, {owner, id}, name: via(id))
  defp via(id), do: {:via, Registry, {ManaspritesDesktop.Fountain.Registry, id}}

  def wake(owner, id) do
    case DynamicSupervisor.start_child(
           ManaspritesDesktop.Fountain.Workers,
           {__MODULE__, {owner, id}}
         ) do
      {:ok, pid} -> send(pid, :work)
      {:error, {:already_started, pid}} -> send(pid, :work)
    end

    :ok
  end

  @impl true
  def init({owner, id}) do
    Process.flag(:trap_exit, true)
    send(self(), :work)
    {:ok, %{owner: owner, id: id, task: nil}}
  end

  @impl true
  def terminate(_, %{task: task}) do
    if task, do: Task.Supervisor.terminate_child(ManaspritesDesktop.Jobs, task.pid)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted})

  @impl true
  def handle_info(:work, state) do
    c = Store.get(state.owner, "conversation", state.id)

    cond do
      is_nil(c) ->
        {:stop, :normal, state}

      (c["_action"] == "terminate" and state.task) && state.task.op != :terminate ->
        Task.Supervisor.terminate_child(ManaspritesDesktop.Jobs, state.task.pid)
        Process.demonitor(state.task.ref, [:flush])
        {:noreply, dispatch(%{state | task: nil}, c)}

      state.task ->
        {:noreply, state}

      true ->
        {:noreply, dispatch(state, c)}
    end
  end

  def handle_info({ref, result}, %{task: %{ref: ref, op: op}} = state) do
    Process.demonitor(ref, [:flush])
    apply_result(state, op, result)
    Process.send_after(self(), :work, if(match?({:error, _}, result), do: 2000, else: 100))
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %{ref: ref, op: op}} = state) do
    apply_result(state, op, {:error, "operation_outcome_unknown"})
    Process.send_after(self(), :work, 2000)
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp dispatch(state, c) do
    op =
      cond do
        c["_action"] == "terminate" -> :terminate
        c["_phase"] == "provision" -> :provision
        c["_phase"] == "prompt" -> :prompt
        c["_phase"] == "running" -> :sync
        true -> nil
      end

    if op do
      task =
        Task.Supervisor.async(ManaspritesDesktop.Jobs, fn ->
          execute(op, state.owner, c)
        end)

      %{state | task: %{ref: task.ref, pid: task.pid, op: op}}
    else
      state
    end
  end

  defp execute(:provision, owner, c), do: Fountain.backend().provision(owner, c)
  defp execute(:terminate, owner, c), do: Fountain.backend().destroy(owner, c)

  defp execute(:prompt, owner, c) do
    operation = c["_operation"]

    if c["_remote_id"] do
      case Fountain.backend().request(
             owner,
             c,
             :post,
             "/api/conversations/#{c["_remote_id"]}/prompts",
             %{"prompt" => operation["prompt"]},
             operation["id"]
           ) do
        {:ok, _} -> {:ok, c["_remote_id"]}
        error -> error
      end
    else
      case Fountain.backend().request(
             owner,
             c,
             :post,
             "/api/conversations",
             %{"agent_id" => "default", "prompt" => operation["prompt"]},
             operation["id"]
           ) do
        {:ok, %{"data" => %{"id" => id}}} -> {:ok, id}
        error -> error
      end
    end
  end

  defp execute(:sync, owner, c) do
    base = "/api/conversations/" <> c["_remote_id"]

    with {:ok, %{"data" => events}} <-
           Fountain.backend().request(
             owner,
             c,
             :get,
             base <> "/events?blocks=true&limit=1000&after=#{c["_cursor"]}"
           ),
         {:ok, %{"data" => turns}} <- Fountain.backend().request(owner, c, :get, base <> "/turns"),
         {:ok, %{"data" => remote}} <- Fountain.backend().request(owner, c, :get, base) do
      {:ok, events, turns, remote}
    end
  end

  defp apply_result(state, op, result) do
    Store.transaction(fn ->
      c = Store.fetch!(state.owner, "conversation", state.id)
      attrs = result_attrs(state.owner, c, op, result)
      Store.patch(state.owner, "conversation", state.id, attrs)
    end)
  end

  defp result_attrs(owner, c, :provision, {:ok, extra}) do
    Store.stage(owner, c["id"], "provision", "done")

    base =
      Map.merge(extra, %{
        "sandbox" => Map.put(c["sandbox"], "status", "ready"),
        "_phase" => "idle",
        "status" => "idle"
      })

    if c["_initial_prompt"] do
      Map.merge(base, %{
        "_phase" => "prompt",
        "status" => "running",
        "_initial_prompt" => nil,
        "_operation" => %{"id" => Store.id(), "prompt" => c["_initial_prompt"]}
      })
    else
      base
    end
  end

  defp result_attrs(owner, c, :provision, _) do
    Store.stage(owner, c["id"], "provision", "failed", %{"error" => "provision_failed"})
    %{"_phase" => "failed", "status" => "failed"}
  end

  defp result_attrs(_, _, :prompt, {:ok, id}), do: %{"_remote_id" => id, "_phase" => "running"}
  # Reusing the saved idempotency key is safe even if the create/prompt reply was lost.
  # Never create a new operation identity during reconciliation.
  defp result_attrs(_, _, :prompt, _), do: %{"_error" => "prompt_acknowledgement_unknown"}

  defp result_attrs(owner, c, :sync, {:ok, events, turns, remote}) do
    for event <- events do
      normalized =
        if event["kind"] in ~w(output stage),
          do: event,
          else: event |> Map.put("kind", "output") |> Map.put("stream", "permission")

      normalized =
        if event["stage"] == "turn" do
          turn = Enum.find(turns, &(&1["id"] == event["turn_id"])) || %{}

          metadata =
            Jason.decode!(event["data"] || "{}")
            |> Map.merge(%{"turn_id" => event["turn_id"], "turn_number" => turn["turn_number"]})

          Map.put(normalized, "data", Jason.encode!(metadata))
        else
          normalized
        end

      Store.event(owner, c["id"], "remote:#{event["id"]}", normalized)
    end

    cursor = (List.last(events) || %{})["id"] || c["_cursor"]
    # A terminal turn row may be visible before its event page is drained.
    terminal =
      c["_terminal_seen"] == true or
        Enum.any?(events, &(&1["stage"] == "turn" and &1["state"] in ~w(done failed interrupted)))

    done =
      remote["status"] in ~w(idle failed terminated) and
        terminal and
        length(events) < 1000

    %{
      "_cursor" => cursor,
      "_terminal_seen" => terminal,
      "_turns" => turns,
      "turn_count" => length(turns),
      "usage_total" => remote["usage_total"],
      "runtime_session_id" => remote["runtime_session_id"],
      "status" => if(done, do: remote["status"], else: "running"),
      "_phase" => if(done, do: "idle", else: "running"),
      "_error" => nil
    }
  end

  defp result_attrs(_, _, :sync, _), do: %{"_error" => "remote_unavailable"}

  defp result_attrs(owner, c, :terminate, :ok) do
    Store.stage(owner, c["id"], "terminate", "done")

    %{
      "_phase" => "terminated",
      "_action" => nil,
      "status" => "terminated",
      "_error" => nil,
      "sandbox" => Map.put(c["sandbox"], "status", "terminated"),
      "_turns" =>
        Enum.map(c["_turns"], fn turn ->
          if turn["status"] in ~w(pending running),
            do: Map.merge(turn, %{"status" => "interrupted", "ended_at" => Store.now()}),
            else: turn
        end)
    }
  end

  defp result_attrs(_, _, :terminate, _),
    do: %{"_phase" => "cleanup_failed", "_action" => nil, "_error" => "cleanup_failed"}
end

defmodule ManaspritesDesktop.Fountain.Supervisor do
  use Supervisor
  alias ManaspritesDesktop.Fountain.{Store, Worker}
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_) do
    children = [
      {Registry, keys: :unique, name: ManaspritesDesktop.Fountain.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: ManaspritesDesktop.Fountain.Workers},
      %{
        id: :fountain_recovery,
        restart: :temporary,
        start:
          {Task, :start_link,
           [
             fn ->
               for {owner, c} <- Store.all("conversation"),
                   c["_phase"] != "terminated",
                   do: Worker.wake(owner, c["id"])
             end
           ]}
      }
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
