defmodule ManaspritesDesktop.Fountain.Store do
  @moduledoc "Account-scoped API state. Transactions serialize admission and event projection."
  alias ManaspritesDesktop.Repo

  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  def id, do: Ecto.UUID.generate()
  def digest(key), do: :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  def transaction(fun), do: Repo.transaction(fun, timeout: 30_000)
  def abort(code, status \\ 422), do: Repo.rollback({status, code})

  def query(sql, args \\ []),
    do: Ecto.Adapters.SQL.query!(Repo, sql, args, log: false)

  def get(owner, kind, id) do
    case query("SELECT record FROM fountain_objects WHERE owner=? AND kind=? AND id=?", [
           owner,
           kind,
           id
         ]).rows do
      [[record]] -> Jason.decode!(record)
      [] -> nil
    end
  end

  def fetch!(owner, kind, id), do: get(owner, kind, id) || abort("not_found", 404)

  def list(owner, kind) do
    query("SELECT record FROM fountain_objects WHERE owner=? AND kind=? ORDER BY rowid", [
      owner,
      kind
    ]).rows
    |> Enum.map(fn [record] -> Jason.decode!(record) end)
  end

  def all(kind) do
    query("SELECT owner,record FROM fountain_objects WHERE kind=?", [kind]).rows
    |> Enum.map(fn [owner, record] -> {owner, Jason.decode!(record)} end)
  end

  def put(owner, kind, record) do
    query(
      "INSERT INTO fountain_objects(id,owner,kind,record) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET record=excluded.record WHERE owner=excluded.owner AND kind=excluded.kind",
      [record["id"], owner, kind, Jason.encode!(record)]
    )

    record
  end

  def patch(owner, kind, id, attrs) do
    record = fetch!(owner, kind, id)
    put(owner, kind, Map.merge(record, attrs))
  end

  def delete(owner, kind, id),
    do: query("DELETE FROM fountain_objects WHERE owner=? AND kind=? AND id=?", [owner, kind, id])

  def public(record), do: Map.reject(record, fn {k, _} -> String.starts_with?(k, "_") end)

  def event(owner, cid, source, event) do
    query(
      "INSERT INTO fountain_events(owner,conversation_id,source_id,record) VALUES(?,?,?,?) ON CONFLICT(conversation_id,source_id) DO NOTHING",
      [owner, cid, to_string(source), Jason.encode!(Map.delete(event, "id"))]
    )
  end

  def stage(owner, cid, stage, state, data \\ %{}) do
    event(owner, cid, id(), %{
      "kind" => "stage",
      "stream" => "stage",
      "stage" => stage,
      "state" => state,
      "ts" => now(),
      "data" => Jason.encode!(data)
    })
  end

  def events(owner, cid, after_id, limit) do
    {where, args} =
      if cid,
        do: {"AND conversation_id=?", [owner, after_id, cid, limit]},
        else: {"", [owner, after_id, limit]}

    query(
      "SELECT id,conversation_id,record FROM fountain_events WHERE owner=? AND id>? #{where} ORDER BY id LIMIT ?",
      args
    ).rows
    |> Enum.map(fn [id, conversation, record] ->
      value = Jason.decode!(record) |> Map.put("id", id)
      if cid, do: value, else: Map.put(value, "conversation_id", conversation)
    end)
  end
end
