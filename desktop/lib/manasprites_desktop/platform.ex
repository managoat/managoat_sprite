defmodule ManaspritesDesktop.Platform do
  @moduledoc "Durable platform operations, independent of any open LiveView."
  use GenServer
  import Ecto.Query
  alias ManaspritesDesktop.{Repo, PlatformJob, ProvisionConfig, Vault, Fleet, PlatformClient}
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def jobs,
    do:
      Repo.all(
        from(j in PlatformJob,
          order_by: [
            asc: fragment("CASE WHEN ? = 'completed' THEN 1 ELSE 0 END", j.state),
            desc: j.inserted_at
          ]
        )
      )

  def get(id), do: Repo.get(PlatformJob, id)

  def discover do
    with {:ok, token} <- Vault.get("sprites") do
      org = token |> String.split("/", parts: 3) |> List.first()
      save(%PlatformJob{kind: "discover", organization: org}, %{"sprites" => token})
    end
  end

  def create(attrs) do
    with {:ok, config} <- ProvisionConfig.build(attrs),
         {:ok, platform} <- Vault.get("sprites"),
         :ok <- token_organization(platform, config["org"]),
         {:ok, inference} <-
           Vault.get(if(config["agent"]["runtime"] == "codex", do: "openai", else: "anthropic")),
         {:ok, git} <- git_key(attrs) do
      key = "mgt_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      save(
        %PlatformJob{
          kind: "create",
          config: config,
          sprite_name: config["name"],
          organization: config["org"]
        },
        %{"sprites" => platform, "inference" => inference, "github" => git, "client_key" => key}
      )
    end
  end

  def retry(id) do
    with %PlatformJob{state: state} = job when state in ~w(failed unknown) <- get(id),
         {:ok, token} <- Vault.get("sprites"),
         :ok <-
           if(job.kind == "discover", do: :ok, else: token_organization(token, job.organization)),
         {:ok, raw} <- Vault.get("platform:" <> id),
         {:ok, secrets} <- Jason.decode(raw),
         :ok <- Vault.put("platform:" <> id, Jason.encode!(Map.put(secrets, "sprites", token))) do
      enqueue_retry(id)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :operation_active}
    end
  end

  defp enqueue_retry(id) do
    {count, _} =
      Repo.update_all(
        from(j in PlatformJob, where: j.id == ^id and j.state in ~w(failed unknown)),
        set: [state: "queued", error: nil, updated_at: DateTime.utc_now()]
      )

    if count == 1 do
      GenServer.cast(__MODULE__, :dispatch)
      Fleet.notify()
      :ok
    else
      {:error, :operation_active}
    end
  end

  def progress(id, fields) do
    Repo.update_all(from(j in PlatformJob, where: j.id == ^id),
      set: fields ++ [updated_at: DateTime.utc_now()]
    )

    Fleet.notify()
  end

  defp git_key(%{"use_github" => "true"}), do: Vault.get("github")
  defp git_key(_), do: {:ok, nil}

  defp token_organization(token, org) do
    case String.split(token, "/", parts: 3) do
      [^org, id, secret] when id != "" and secret != "" -> :ok
      _ -> {:error, :wrong_organization}
    end
  end

  defp save(job, secrets) do
    job = %{job | id: Ecto.UUID.generate()}

    with {:ok, sealed} <- Vault.seal("platform:" <> job.id, Jason.encode!(secrets)),
         {:ok, job} <-
           Repo.transaction(fn ->
             cs =
               Ecto.Changeset.change(job)
               |> Ecto.Changeset.unique_constraint([:organization, :sprite_name])

             case Repo.insert(cs) do
               {:ok, inserted} ->
                 Repo.insert_all(
                   ManaspritesDesktop.Credential,
                   [%{name: "platform:" <> job.id, ciphertext: sealed}],
                   log: false
                 )

                 inserted

               {:error, error} ->
                 Repo.rollback(error)
             end
           end) do
      GenServer.cast(__MODULE__, :dispatch)
      Fleet.notify()
      {:ok, job}
    end
  end

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)

    Repo.update_all(from(j in PlatformJob, where: j.state == "running"),
      set: [
        state: "unknown",
        error:
          "The app closed during this operation. Review and resume to reconcile the existing Sprite."
      ]
    )

    Fleet.notify()
    {:ok, %{}, {:continue, :dispatch}}
  end

  @impl true
  def handle_continue(:dispatch, state), do: {:noreply, dispatch(state)}
  @impl true
  def handle_cast(:dispatch, state), do: {:noreply, dispatch(state)}
  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state, ref) do
      {nil, state} ->
        {:noreply, state}

      {%{job: id}, state} ->
        Process.demonitor(ref, [:flush])

        case result do
          {:ok, value} ->
            Repo.transaction(fn ->
              Repo.update_all(from(j in PlatformJob, where: j.id == ^id),
                set: [
                  state: "completed",
                  result: value,
                  error: nil,
                  updated_at: DateTime.utc_now()
                ]
              )

              Vault.delete("platform:" <> id)
            end)

            Fleet.notify()

          {:error, error} ->
            progress(id, state: "failed", error: PlatformClient.message(error))
        end

        {:noreply, dispatch(state)}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    case Map.pop(state, ref) do
      {nil, state} ->
        {:noreply, state}

      {%{job: id}, state} ->
        progress(id,
          state: "unknown",
          error:
            "The operation stopped without acknowledgement. Review and resume to reconcile remote state."
        )

        {:noreply, dispatch(state)}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp dispatch(state) do
    # A small concurrency limit bounds laptop resources while separate Sprites
    # install independently. Reads and creations have their own durable records.
    jobs =
      Repo.all(
        from(j in PlatformJob,
          where: j.state == "queued",
          order_by: j.inserted_at,
          limit: ^max(0, 4 - map_size(state))
        )
      )

    Enum.reduce(jobs, state, fn job, state ->
      progress(job.id, state: "running")

      task =
        Task.Supervisor.async(ManaspritesDesktop.Jobs, fn ->
          ManaspritesDesktop.Provisioner.run(get(job.id))
        end)

      Map.put(state, task.ref, %{job: job.id, pid: task.pid})
    end)
  end

  @impl true
  def terminate(_, state) do
    Enum.each(state, fn {_, task} ->
      Task.Supervisor.terminate_child(ManaspritesDesktop.Jobs, task.pid)
    end)

    :ok
  catch
    :exit, _ -> :ok
  end
end
