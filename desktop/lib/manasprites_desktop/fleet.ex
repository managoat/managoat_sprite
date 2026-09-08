defmodule ManaspritesDesktop.Fleet do
  @moduledoc "Durable local fleet, operation admission, and remote history cache."
  import Ecto.Query
  alias ManaspritesDesktop.{Agent, Job, Repo, Vault, Connection}

  def list, do: Repo.all(from(a in Agent, order_by: [asc: a.inserted_at, asc: a.id]))
  def get(id), do: Repo.get(Agent, id)

  def prompt_pending?(aid),
    do:
      Repo.exists?(
        from(j in Job,
          where:
            j.agent_id == ^aid and j.kind == "prompt" and j.state in ~w(queued running unknown)
        )
      )

  def jobs(aid),
    do:
      Repo.all(
        from(j in Job,
          where: j.agent_id == ^aid,
          order_by: [
            asc:
              fragment(
                "CASE WHEN ? = 'unknown' THEN 0 WHEN ? IN ('queued', 'running') THEN 1 ELSE 2 END",
                j.state,
                j.state
              ),
            desc: j.inserted_at
          ],
          limit: 20
        )
      )

  def conversations(agent), do: agent.snapshot["conversations"] || []
  def busy?(agent), do: Enum.any?(conversations(agent), &(&1["status"] in ~w(pending running)))

  def approval_requested?(agent) do
    Enum.any?(conversations(agent), fn conversation ->
      if conversation["status"] in ~w(pending running) do
        cid = conversation["id"]

        active =
          turns(agent.id, cid)
          |> Enum.filter(&(&1["status"] in ~w(pending running)))
          |> Enum.map(& &1["id"])

        # The ACP peer holds one permission at a time. A subsequent request
        # supersedes the previous one. Query the full cache, not the UI's page.
        event =
          Repo.one(
            from(e in ManaspritesDesktop.EventCache,
              where:
                e.agent_id == ^agent.id and e.conversation_id == ^cid and
                  fragment("json_extract(?, '$.turn_id')", e.record) in ^active and
                  fragment(
                    "EXISTS (SELECT 1 FROM json_each(json_extract(?, '$.blocks')) WHERE json_extract(value, '$.kind') = 'permission_request')",
                    e.record
                  ),
              order_by: [desc: e.remote_id],
              limit: 1,
              select: e.record
            )
          )

        if event do
          Enum.any?(event["blocks"] || [], fn block ->
            block["kind"] == "permission_request" and
              not permission_answered?(agent.id, cid, block["request_id"])
          end)
        else
          false
        end
      else
        false
      end
    end)
  end

  def permission_answered?(aid, cid, rid) do
    Repo.exists?(
      from(j in Job,
        where:
          j.agent_id == ^aid and j.kind == "permission" and j.state == "completed" and
            fragment("json_extract(?, '$.conversation_id')", j.payload) == ^cid and
            fragment("json_extract(?, '$.request_id')", j.payload) == ^rid
      )
    )
  end

  def notify, do: Phoenix.PubSub.broadcast(ManaspritesDesktop.PubSub, "fleet", :changed)

  def attach(attrs, key) do
    agent = %Agent{id: Ecto.UUID.generate()}
    attrs = Map.update(attrs, "url", "", &String.trim_trailing(String.trim(&1), "/"))

    attrs =
      if attrs["transport"] == "private",
        do: Map.put(attrs, "url", "sprite://#{attrs["organization"]}/#{attrs["sprite_name"]}"),
        else: attrs

    changeset = Agent.changeset(agent, attrs)

    if changeset.valid? do
      with {:ok, ciphertext} <- Vault.seal("agent:" <> agent.id, key),
           {:ok, job} <-
             Repo.transaction(fn ->
               case Repo.insert(changeset) do
                 {:ok, _} -> :ok
                 {:error, error} -> Repo.rollback(error)
               end

               Repo.insert_all(
                 ManaspritesDesktop.Credential,
                 [%{name: "agent:" <> agent.id, ciphertext: ciphertext}],
                 log: false
               )

               Repo.insert!(%Job{agent_id: agent.id, kind: "connect"})
             end) do
        Connection.enqueue(job)
        notify()
        {:ok, agent.id}
      end
    else
      {:error, changeset}
    end
  end

  def update_key(aid, key) do
    with %Agent{} <- get(aid),
         :ok <- Vault.put("agent:" <> aid, key),
         do: submit(aid, "connect", %{})
  end

  def submit(aid, kind, payload)
      when kind in ~w(connect sync prompt interrupt permission workspace) do
    cond do
      is_nil(get(aid)) ->
        {:error, :agent_missing}

      not valid_payload?(kind, payload) ->
        {:error, :invalid_request}

      true ->
        changeset =
          Ecto.Changeset.change(%Job{}, agent_id: aid, kind: kind, payload: payload)
          |> Ecto.Changeset.unique_constraint(:agent_id, name: :jobs_agent_id_index)

        case Repo.insert(changeset) do
          {:ok, job} ->
            Connection.enqueue(job)
            notify()
            {:ok, job}

          {:error, _} ->
            {:error, :submission_pending}
        end
    end
  end

  def resolve_unknown(aid, jid) do
    # User has reviewed remote conversations. This only clears the local hold;
    # it never resends or changes remote work.
    {count, _} =
      Repo.update_all(
        from(j in Job, where: j.id == ^jid and j.agent_id == ^aid and j.state == "unknown"),
        set: [state: "reviewed", updated_at: DateTime.utc_now()]
      )

    notify()
    if count == 1, do: :ok, else: {:error, :job_not_unknown}
  end

  def remove(aid) do
    Repo.transaction(fn ->
      if Repo.exists?(
           from(j in Job, where: j.agent_id == ^aid and j.state in ~w(queued running))
         ),
         do: Repo.rollback(:operation_active)

      Repo.delete_all(from(a in Agent, where: a.id == ^aid))

      Repo.delete_all(
        from(c in ManaspritesDesktop.Credential, where: c.name == ^("agent:" <> aid))
      )
    end)
    |> case do
      {:ok, _} ->
        Connection.stop(aid)
        notify()
        :ok

      error ->
        error
    end
  end

  def turns(aid, cid) do
    case Repo.one(
           from(c in ManaspritesDesktop.ConversationCache,
             where: c.agent_id == ^aid and c.remote_id == ^cid,
             select: c.turns
           )
         ) do
      nil ->
        []

      %{"data" => rows} ->
        # Query the full cached protocol history, independently of UI pagination.
        warnings =
          Repo.all(
            from(e in ManaspritesDesktop.EventCache,
              where:
                e.agent_id == ^aid and e.conversation_id == ^cid and
                  fragment("instr(json_extract(?, '$.data'), '_meta') > 0", e.record),
              order_by: [asc: e.remote_id],
              select: e.record
            )
          )
          |> Enum.reduce(%{}, fn event, acc ->
            case ManaspritesDesktop.ProviderDiagnostics.warning(event["data"]) do
              nil -> acc
              warning -> Map.put(acc, event["turn_id"], warning)
            end
          end)

        Enum.map(rows, &Map.put(&1, "desktop_warning", warnings[&1["id"]]))
    end
  end

  def provider_warning?(agent) do
    Enum.any?(conversations(agent), fn conversation ->
      case Enum.max_by(turns(agent.id, conversation["id"]), & &1["turn_number"], fn -> nil end) do
        nil -> false
        turn -> not is_nil(turn["desktop_warning"])
      end
    end)
  end

  def events(aid, cid, limit \\ 2000) do
    Repo.all(
      from(e in ManaspritesDesktop.EventCache,
        where: e.agent_id == ^aid and e.conversation_id == ^cid,
        order_by: [desc: e.remote_id],
        limit: ^limit,
        select: e.record
      )
    )
    |> Enum.reverse()
  end

  def cursor(aid, cid),
    do:
      Repo.one(
        from(e in ManaspritesDesktop.EventCache,
          where: e.agent_id == ^aid and e.conversation_id == ^cid,
          select: max(e.remote_id)
        )
      ) || 0

  def cache_turns(aid, cid, turns) do
    Repo.insert_all(
      ManaspritesDesktop.ConversationCache,
      [%{agent_id: aid, remote_id: cid, turns: %{"data" => turns}}],
      on_conflict: {:replace, [:turns]},
      conflict_target: [:agent_id, :remote_id],
      log: false
    )
  end

  def cache_events(aid, cid, events) do
    rows =
      Enum.map(events, &%{agent_id: aid, conversation_id: cid, remote_id: &1["id"], record: &1})

    # Keep SQLite's parameter limit independent of the remote page size.
    Enum.each(
      Enum.chunk_every(rows, 100),
      &Repo.insert_all(ManaspritesDesktop.EventCache, &1, on_conflict: :nothing, log: false)
    )
  end

  def valid_id?(value), do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, value)

  defp valid_payload?("prompt", payload),
    do:
      is_binary(payload["prompt"]) and byte_size(String.trim(payload["prompt"])) in 1..262_144 and
        (is_nil(payload["conversation_id"]) or valid_id?(payload["conversation_id"]))

  defp valid_payload?("permission", p),
    do:
      valid_id?(p["conversation_id"]) and valid_opaque_id?(p["request_id"]) and
        valid_opaque_id?(p["option_id"])

  defp valid_payload?("interrupt", p), do: valid_id?(p["conversation_id"])

  defp valid_payload?("sync", p),
    do: is_nil(p["conversation_id"]) or valid_id?(p["conversation_id"])

  defp valid_payload?("connect", _), do: true
  defp valid_payload?("workspace", payload), do: ManaspritesDesktop.Workspace.valid?(payload)

  defp valid_opaque_id?(value),
    do: is_binary(value) and byte_size(value) in 1..1024 and String.valid?(value)
end
