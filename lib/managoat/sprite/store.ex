defmodule Managoat.Sprite.Store do
  @moduledoc "Serialized transactional admission and durable events; HTTP and execution never own the database."
  use GenServer
  alias Managoat.Sprite.{Repo, Config}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def call(op), do: GenServer.call(__MODULE__, op, 30_000)
  def query(sql, args \\ []), do: Ecto.Adapters.SQL.query!(Repo, sql, args, log: false)
  def rows(sql, args \\ []), do: query(sql, args).rows
  def digest(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)

  @impl true
  def init(_) do
    Ecto.Migrator.run(
      Repo,
      [
        {20_260_907_000_000, Managoat.Sprite.Repo.Migrations.Initialize},
        {20_260_907_000_001, Managoat.Sprite.Repo.Migrations.AgentConfigurations}
      ],
      :up,
      all: true,
      log: false
    )

    query("INSERT OR IGNORE INTO installation(id,identity) VALUES(1,?)", [Config.id()])
    {:ok, %{revision: System.unique_integer([:positive, :monotonic])}}
  end

  @impl true
  def handle_call(:revision, _from, state), do: {:reply, state.revision, state}

  def handle_call(op, _from, state) do
    result = Repo.transaction(fn -> operate(op) end)

    case result do
      {:ok, result} ->
        changed =
          is_tuple(op) and elem(op, 0) in [:admit, :finish, :delete, :terminate, :dispatch]

        state =
          if changed and not match?({:error, _}, result),
            do: %{state | revision: System.unique_integer([:positive, :monotonic])},
            else: state

        {:reply, result, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp operate(:identity),
    do: rows("SELECT identity FROM installation WHERE id=1") |> hd() |> hd()

  defp operate({:key, key}) do
    query("INSERT OR IGNORE INTO api_keys(digest,created_at) VALUES(?,?)", [
      digest(key),
      Config.now()
    ])

    :ok
  end

  defp operate({:rotate_key, key}) do
    query("DELETE FROM api_keys")
    operate({:key, key})
  end

  defp operate({:auth, key}) when is_binary(key),
    do: rows("SELECT digest FROM api_keys WHERE digest=?", [digest(key)]) != []

  defp operate({:auth, _}), do: false

  defp operate(:active) do
    case rows("SELECT record,phase FROM turns WHERE active=1") do
      [[r, phase]] -> Map.put(Jason.decode!(r), "phase", phase)
      [] -> nil
    end
  end

  defp operate({:get, id}), do: get_conversation(id)

  defp operate(:conversations),
    do: records("SELECT record FROM conversations ORDER BY rowid DESC")

  defp operate({:turns, id}),
    do: records("SELECT record FROM turns WHERE conversation_id=? ORDER BY number", [id])

  defp operate({:turn, id}), do: one("SELECT record FROM turns WHERE id=?", [id])

  defp operate({:launch, id}) do
    turn = operate({:turn, id})
    conversation = turn && get_conversation(turn["conversation_id"])

    with :ok <- compatible_configuration(conversation) do
      policy =
        Managoat.ACP.Permissions.effective(Config.get()["permissions"], turn["permission_policy"])

      query("UPDATE turns SET record=? WHERE id=?", [
        Jason.encode!(Map.put(turn, "permission_policy", policy)),
        id
      ])

      :ok
    end
  end

  defp operate({:permission, id}), do: one("SELECT record FROM permissions WHERE id=?", [id])
  defp operate(:latest), do: rows("SELECT coalesce(max(id),0) FROM events") |> hd() |> hd()

  defp operate({:events, id, after_id, limit, streams}) do
    {where, args} =
      if id, do: {"id > ? AND conversation_id = ?", [after_id, id]}, else: {"id > ?", [after_id]}

    {where, args} =
      if streams == [],
        do: {where, args},
        else:
          {where <>
             " AND json_extract(record,'$.stream') IN (" <>
             Enum.map_join(streams, ",", fn _ -> "?" end) <> ")", args ++ streams}

    rows("SELECT id,record FROM events WHERE #{where} ORDER BY id LIMIT ?", args ++ [limit])
    |> Enum.map(fn [id, r] -> Map.put(Jason.decode!(r), "id", id) end)
  end

  defp operate({:admit, id, attrs, key}) do
    operation = if id, do: "prompt:" <> id, else: "create"
    fingerprint = digest(:erlang.term_to_binary(Enum.sort(attrs)))
    scoped = if key, do: operation <> ":" <> key

    case scoped &&
           rows("SELECT fingerprint,response,deleted FROM idempotency WHERE key=?", [scoped]) do
      [[_, _, 1]] -> {:error, {410, "gone"}}
      [[^fingerprint, response, 0]] -> {:ok, Jason.decode!(response), :replayed}
      [[_, _, _]] -> {:error, {409, "idempotency_conflict"}}
      _ -> admit(id, attrs, scoped, fingerprint)
    end
  end

  defp operate({:replay, id, attrs, key}) do
    operation = if id, do: "prompt:" <> id, else: "create"
    fingerprint = digest(:erlang.term_to_binary(Enum.sort(attrs)))
    scoped = if key, do: operation <> ":" <> key

    case scoped &&
           rows("SELECT fingerprint,response,deleted FROM idempotency WHERE key=?", [scoped]) do
      [[_, _, 1]] -> {:error, {410, "gone"}}
      [[^fingerprint, response, 0]] -> {:ok, Jason.decode!(response)}
      [[_, _, _]] -> {:error, {409, "idempotency_conflict"}}
      _ -> :missing
    end
  end

  defp operate({:dispatch, turn_id, request_id}) do
    case operate(:active) do
      %{"id" => ^turn_id, "phase" => "pending"} = t ->
        t =
          Map.merge(t, %{
            "status" => "running",
            "started_at" => Config.now(),
            "acp_prompt_id" => request_id
          })

        save_turn(t, "dispatching", true)
        stage(t, "started")
        :ok

      _ ->
        {:error, :not_pending}
    end
  end

  defp operate({:session, cid, sid}) do
    c = get_conversation(cid)
    save_conversation(Map.put(c, "runtime_session_id", sid))
    :ok
  end

  defp operate({:model, tid, model}) do
    t = operate({:turn, tid})

    query("UPDATE turns SET record=? WHERE id=?", [
      Jason.encode!(Map.put(t, "model_selection", model)),
      tid
    ])

    :ok
  end

  defp operate({:output, cid, tid, stream, data}) do
    event(cid, tid, %{"kind" => "output", "stream" => stream, "data" => data})
  end

  defp operate({:ask, cid, tid, rid, tool, options, deadline}) do
    p = %{
      "id" => rid,
      "conversation_id" => cid,
      "turn_id" => tid,
      "tool" => tool,
      "options" => options,
      "deadline" => deadline,
      "status" => "pending"
    }

    query("INSERT INTO permissions(id,conversation_id,turn_id,record) VALUES(?,?,?,?)", [
      rid,
      cid,
      tid,
      Jason.encode!(p)
    ])

    :ok
  end

  defp operate({:resolve, cid, rid, option}) do
    case operate({:permission, rid}) do
      %{"conversation_id" => ^cid, "status" => "pending"} = p ->
        cond do
          p["deadline"] <= System.system_time(:millisecond) ->
            {:error, {409, "permission_request_resolved"}}

          not Enum.any?(p["options"], &(&1["optionId"] == option)) ->
            {:error, {422, "unknown_option"}}

          true ->
            p = Map.merge(p, %{"status" => "resolved", "option_id" => option})
            query("UPDATE permissions SET record=? WHERE id=?", [Jason.encode!(p), rid])
            :ok
        end

      _ ->
        {:error, {409, "permission_request_resolved"}}
    end
  end

  defp operate({:expire, rid}) do
    if p = operate({:permission, rid}) do
      query("UPDATE permissions SET record=? WHERE id=?", [
        Jason.encode!(Map.put(p, "status", "resolved")),
        rid
      ])
    end

    :ok
  end

  defp operate({:finish, tid, status, reason, usage}) do
    case operate(:active) do
      %{"id" => ^tid} = t ->
        t =
          Map.merge(t, %{
            "status" => status,
            "failure_reason" => reason,
            "usage" => usage,
            "ended_at" => Config.now()
          })

        save_turn(t, "finished", false)

        query(
          "UPDATE permissions SET record=json_set(record,'$.status','resolved') WHERE turn_id=?",
          [tid]
        )

        c = get_conversation(t["conversation_id"])
        totals = c["usage_total"]

        totals =
          if usage,
            do: Map.new(totals, fn {k, v} -> {k, v + Map.get(usage, k, 0)} end),
            else: totals

        save_conversation(
          Map.merge(c, %{
            "status" => "idle",
            "last_active_at" => Config.now(),
            "usage_total" => totals
          })
        )

        stage(t, if(status == "completed", do: "done", else: status))
        :ok

      _ ->
        :ok
    end
  end

  defp operate({:terminate, cid}) do
    if c = get_conversation(cid) do
      save_conversation(Map.put(c, "status", "terminated"))
      :ok
    else
      {:error, {404, "not_found"}}
    end
  end

  defp operate({:delete, cid}) do
    if get_conversation(cid) do
      query("UPDATE idempotency SET deleted=1 WHERE conversation_id=?", [cid])
      query("DELETE FROM conversations WHERE id=?", [cid])
      :ok
    else
      {:error, {404, "not_found"}}
    end
  end

  defp admit(id, attrs, key, fingerprint) do
    existing = id && get_conversation(id)
    active = operate(:active)

    cond do
      id && is_nil(existing) ->
        {:error, {404, "not_found"}}

      existing && existing["status"] in ["terminated", "failed"] ->
        {:error, {410, "gone"}}

      existing && compatible_configuration(existing) != :ok ->
        compatible_configuration(existing)

      active && active["conversation_id"] == id ->
        {:error, {400, "conversation_busy"}}

      active ->
        {:error, {409, "sandbox_at_capacity"}}

      true ->
        c = existing || new_conversation(attrs)
        number = c["turn_count"] + 1
        tid = Config.id()

        t = %{
          "id" => tid,
          "conversation_id" => c["id"],
          "turn_number" => number,
          "prompt" => attrs["prompt"],
          "status" => "pending",
          "origin" => "user",
          "inserted_at" => Config.now(),
          "started_at" => nil,
          "ended_at" => nil,
          "usage" => nil,
          "exit_code" => nil,
          "model_selection" => nil,
          "requested_model" => Config.get()["model"],
          "configuration_id" => c["configuration_id"],
          "permission_policy" =>
            Managoat.ACP.Permissions.effective(
              Config.get()["permissions"],
              c["permission_policy"]
            ),
          "image_count" => 0
        }

        c =
          Map.merge(c, %{
            "status" => "running",
            "turn_count" => number,
            "last_active_at" => Config.now()
          })

        save_conversation(c)
        save_turn(t, "pending", true)

        response =
          if id,
            do: %{"status" => "queued"},
            else: %{"data" => c, "meta" => %{"resumed" => false}}

        if key,
          do:
            query(
              "INSERT INTO idempotency(key,fingerprint,conversation_id,response) VALUES(?,?,?,?)",
              [key, fingerprint, c["id"], Jason.encode!(response)]
            )

        {:ok, response, t}
    end
  end

  defp new_conversation(attrs) do
    config = Config.get()
    launch = Config.launch_configuration()
    configuration_id = digest(:erlang.term_to_binary(Enum.sort(launch)))

    query(
      "INSERT OR IGNORE INTO agents(id,agent_id,record) VALUES(?,?,?)",
      [configuration_id, "default", Jason.encode!(launch)]
    )

    %{
      "id" => Config.id(),
      "title" => attrs["title"],
      "first_prompt" => attrs["prompt"],
      "agent_id" => "default",
      "configuration_id" => configuration_id,
      "runtime" => config["runtime"],
      "acp" => true,
      "status" => "pending",
      "turn_count" => 0,
      "runtime_session_id" => nil,
      "permission_policy" =>
        Managoat.ACP.Permissions.effective(
          config["permissions"],
          attrs["permission_policy"] || %{}
        ),
      "usage_total" => %{"input" => 0, "output" => 0},
      "inserted_at" => Config.now(),
      "updated_at" => Config.now()
    }
  end

  defp compatible_configuration(nil), do: {:error, {404, "not_found"}}

  defp compatible_configuration(c) do
    stored =
      c["configuration_id"] &&
        one("SELECT record FROM agents WHERE id=?", [c["configuration_id"]])

    cond do
      is_nil(stored) -> {:error, {409, "configuration_snapshot_unavailable"}}
      stored != Config.launch_configuration() -> {:error, {409, "configuration_changed"}}
      true -> :ok
    end
  end

  defp get_conversation(id), do: one("SELECT record FROM conversations WHERE id=?", [id])
  defp one(sql, args), do: List.first(records(sql, args))
  defp records(sql, args \\ []), do: Enum.map(rows(sql, args), fn [r] -> Jason.decode!(r) end)

  defp save_conversation(c) do
    c = Map.put(c, "updated_at", Config.now())

    query(
      "INSERT INTO conversations(id,status,record) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET status=excluded.status,record=excluded.record",
      [c["id"], c["status"], Jason.encode!(c)]
    )
  end

  defp save_turn(t, phase, active) do
    query(
      "INSERT INTO turns(id,conversation_id,number,active,phase,record) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET active=excluded.active,phase=excluded.phase,record=excluded.record",
      [
        t["id"],
        t["conversation_id"],
        t["turn_number"],
        if(active, do: 1, else: 0),
        phase,
        Jason.encode!(Map.delete(t, "phase"))
      ]
    )
  end

  defp stage(t, state),
    do:
      event(t["conversation_id"], t["id"], %{
        "kind" => "stage",
        "stream" => "stage",
        "stage" => "turn",
        "state" => state,
        "data" => Jason.encode!(%{"reason" => t["failure_reason"]})
      })

  defp event(cid, tid, attrs) do
    e =
      Map.merge(
        %{
          "conversation_id" => cid,
          "turn_id" => tid,
          "ts" => Config.now(),
          "stage" => nil,
          "state" => nil,
          "duration_ms" => nil,
          "data" => nil
        },
        attrs
      )

    query("INSERT INTO events(conversation_id,turn_id,record) VALUES(?,?,?)", [
      cid,
      tid,
      Jason.encode!(e)
    ])

    :ok
  end

  @impl true
  def format_status(status) do
    # OTP crash reports are operational logs, never a copy of a prompt or key.
    Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted})
  end
end
