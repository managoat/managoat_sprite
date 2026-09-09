defmodule ManaspritesDesktop.Connection do
  @moduledoc "One supervised connection owner per agent. No idle remote polling."
  use GenServer
  import Ecto.Query
  alias ManaspritesDesktop.{Fleet, Job, Repo, ServiceClient, Operations}

  def start_link({aid, workspace?} = args),
    do:
      GenServer.start_link(__MODULE__, args,
        name: via(if(workspace?, do: {:workspace, aid}, else: aid))
      )

  defp via(aid), do: {:via, Registry, {ManaspritesDesktop.Connections, aid}}

  def enqueue(%Job{} = job) do
    case DynamicSupervisor.start_child(
           ManaspritesDesktop.ConnectionSupervisor,
           {__MODULE__, {job.agent_id, job.kind == "workspace"}}
         ) do
      {:ok, pid} -> GenServer.cast(pid, {:job, job.id})
      {:error, {:already_started, pid}} -> GenServer.cast(pid, {:job, job.id})
    end
  end

  def stop(aid) do
    Enum.each([aid, {:workspace, aid}], fn key ->
      case Registry.lookup(ManaspritesDesktop.Connections, key) do
        [{pid, _}] ->
          DynamicSupervisor.terminate_child(ManaspritesDesktop.ConnectionSupervisor, pid)

        [] ->
          :ok
      end
    end)
  end

  @impl true
  def init({aid, workspace?}) do
    Process.flag(:trap_exit, true)
    # An owner restart cannot determine whether its last POST reached the Sprite.
    Repo.update_all(
      from(j in Job,
        where:
          j.agent_id == ^aid and j.state == "running" and j.kind == "workspace" == ^workspace?
      ),
      set: [
        state: if(workspace?, do: "failed", else: "unknown"),
        error:
          if(workspace?,
            do: "The inspector restarted. Refresh to read the workspace again.",
            else: "Connection owner restarted. Review remote work before submitting again."
          )
      ]
    )

    Fleet.notify()

    queue =
      Repo.all(
        from(j in Job,
          where:
            j.agent_id == ^aid and j.state == "queued" and j.kind == "workspace" == ^workspace?,
          order_by: j.inserted_at,
          select: j.id
        )
      )

    {:ok, %{agent_id: aid, workspace?: workspace?, task: nil, job: nil, queue: queue, timer: nil},
     {:continue, :next}}
  end

  @impl true
  def handle_cast({:job, id}, state) do
    queue = if id in state.queue or id == state.job, do: state.queue, else: state.queue ++ [id]
    {:noreply, next(%{state | queue: queue})}
  end

  @impl true
  def handle_continue(:next, state), do: {:noreply, next(state)}

  @impl true
  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    if state.job, do: finish_job(state.job, result)
    Fleet.notify()
    {:noreply, next(schedule(%{state | task: nil, job: nil}))}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %{ref: ref}} = state) do
    if state.job, do: finish_job(state.job, {:error, :connection_failed})
    Fleet.notify()
    {:noreply, next(%{state | task: nil, job: nil})}
  end

  def handle_info(:poll, %{task: nil, queue: []} = state) do
    agent = Fleet.get(state.agent_id)

    if !state.workspace? && agent && Fleet.busy?(agent) && is_nil(agent.error) do
      task =
        Task.Supervisor.async(ManaspritesDesktop.Jobs, fn ->
          Operations.sync(state.agent_id, nil)
        end)

      {:noreply, %{state | task: task, timer: nil}}
    else
      {:noreply, %{state | timer: nil}}
    end
  end

  def handle_info(:poll, state), do: {:noreply, %{state | timer: nil}}
  def handle_info(_, state), do: {:noreply, state}

  defp next(%{task: nil, queue: [jid | rest]} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    {count, _} =
      Repo.update_all(from(j in Job, where: j.id == ^jid and j.state == "queued"),
        set: [state: "running", updated_at: DateTime.utc_now()]
      )

    if count == 1 do
      task =
        Task.Supervisor.async(ManaspritesDesktop.Jobs, fn ->
          Operations.run(Repo.get!(Job, jid))
        end)

      %{state | task: task, job: jid, queue: rest, timer: nil}
    else
      next(%{state | queue: rest})
    end
  end

  defp next(state), do: state

  defp schedule(%{workspace?: true} = state), do: state

  defp schedule(state) do
    agent = Fleet.get(state.agent_id)

    if agent && Fleet.busy?(agent) && is_nil(agent.error) && is_nil(state.timer) do
      %{state | timer: Process.send_after(self(), :poll, 750)}
    else
      state
    end
  end

  defp finish_job(jid, result) do
    job = Repo.get!(Job, jid)

    fields =
      case result do
        {:ok, result} ->
          [state: "completed", result: result, error: nil]

        {:error, error} ->
          certain = match?({:http, code} when code in 400..499, error)
          ambiguous = job.kind in ~w(prompt interrupt permission) and not certain

          [
            state: if(ambiguous, do: "unknown", else: "failed"),
            error:
              if(job.kind == "workspace",
                do: ManaspritesDesktop.Workspace.message(error),
                else: ServiceClient.message(error)
              )
          ]
      end

    Repo.update_all(from(j in Job, where: j.id == ^jid),
      set: fields ++ [updated_at: DateTime.utc_now()]
    )
  end

  @impl true
  def terminate(_, state) do
    if state.task, do: Task.Supervisor.terminate_child(ManaspritesDesktop.Jobs, state.task.pid)
    :ok
  catch
    :exit, _ -> :ok
  end
end
