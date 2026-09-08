defmodule Managoat.Sprite.A2A.Projection do
  @moduledoc "Bounded task-only text, committed in the engine event transaction."
  alias Managoat.Sprite.Store
  @max_text 1_048_576

  def record(tid, event, cursor) do
    case Store.rows("SELECT text,truncated FROM a2a_tasks WHERE id=?", [tid]) do
      [[text, truncated]] ->
        addition =
          if event["kind"] == "output" and event["stream"] == "acp",
            do: assistant_text(event["data"]),
            else: ""

        remaining = max(@max_text - byte_size(text), 0)
        clipped = utf8_prefix(addition, remaining)

        Store.query(
          "UPDATE a2a_tasks SET text=?,truncated=?,updated_at=?,event_id=? WHERE id=?",
          [
            text <> clipped,
            if(truncated == 1 or byte_size(addition) > remaining, do: 1, else: 0),
            event["ts"],
            cursor,
            tid
          ]
        )

      [] ->
        :ok
    end
  end

  defp assistant_text(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&Managoat.ACP.Blocks.from_line/1)
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.map_join("", & &1.body)
  end

  defp utf8_prefix(text, n) when byte_size(text) <= n, do: text

  defp utf8_prefix(text, n) do
    prefix = binary_part(text, 0, n)
    if String.valid?(prefix), do: prefix, else: utf8_prefix(prefix, n - 1)
  end

  def snapshot(id) do
    case Store.rows(
           "SELECT t.record,a.message_id,a.text,a.truncated,a.updated_at,a.event_id FROM a2a_tasks a JOIN turns t ON t.id=a.id WHERE a.id=?",
           [id]
         ) do
      [[record, mid, text, truncated, timestamp, cursor]] ->
        turn = Jason.decode!(record)

        waiting =
          Store.rows(
            "SELECT id FROM permissions WHERE turn_id=? AND json_extract(record,'$.status')='pending' LIMIT 1",
            [id]
          ) != []

        state = state(turn)

        status_text =
          cond do
            waiting and state == "TASK_STATE_WORKING" ->
              "Waiting for the owner to answer a tool approval in Manasprites."

            state == "TASK_STATE_FAILED" ->
              "Task failed: " <> (turn["failure_reason"] || "execution_failed")

            state == "TASK_STATE_CANCELED" ->
              "Task canceled; subprocess cleanup confirmed."

            true ->
              nil
          end

        status = %{"state" => state, "timestamp" => timestamp}

        status =
          if status_text,
            do:
              Map.put(
                status,
                "message",
                message(turn, "status-#{cursor}", "ROLE_AGENT", status_text)
              ),
            else: status

        artifacts =
          if text == "",
            do: [],
            else: [
              %{
                "artifactId" => id <> "-text",
                "name" => "Text result",
                "metadata" => %{"textTruncated" => truncated == 1},
                "parts" => [%{"text" => text}]
              }
            ]

        history =
          [message(turn, mid, "ROLE_USER", turn["prompt"])] ++
            if(text == "", do: [], else: [message(turn, id <> "-result", "ROLE_AGENT", text)])

        {%{
           "id" => id,
           "contextId" => turn["conversation_id"],
           "status" => status,
           "artifacts" => artifacts,
           "history" => history,
           "metadata" => %{"textTruncated" => truncated == 1}
         }, cursor}

      [] ->
        nil
    end
  end

  defp message(t, id, role, text),
    do: %{
      "messageId" => id,
      "taskId" => t["id"],
      "contextId" => t["conversation_id"],
      "role" => role,
      "parts" => [%{"text" => text}]
    }

  def state(t) do
    case t["status"] do
      "pending" ->
        "TASK_STATE_SUBMITTED"

      "running" ->
        "TASK_STATE_WORKING"

      "completed" ->
        "TASK_STATE_COMPLETED"

      "interrupted" ->
        if(t["failure_reason"] in ~w(explicit_cancel explicit_cancel_forced),
          do: "TASK_STATE_CANCELED",
          else: "TASK_STATE_FAILED"
        )

      _ ->
        "TASK_STATE_FAILED"
    end
  end

  def terminal?(task),
    do: task["status"]["state"] not in ~w(TASK_STATE_SUBMITTED TASK_STATE_WORKING)

  def history(task, nil), do: task
  def history(task, 0), do: Map.put(task, "history", [])
  def history(task, limit), do: Map.update!(task, "history", &Enum.take(&1, -limit))

  def list(p) do
    filters = Map.drop(p, ["pageToken", "pageSize"])
    fingerprint = Store.digest(:erlang.term_to_binary(filters))

    with {:ok, cursor} <- cursor(p["pageToken"], fingerprint) do
      {clauses, args} =
        Enum.reduce(
          [
            {"contextId", "t.conversation_id"},
            {"status", "state"},
            {"statusTimestampAfter", "a.updated_at"}
          ],
          {[], []},
          fn {key, col}, {clauses, args} ->
            if p[key] && p[key] != "",
              do:
                {clauses ++
                   [
                     if(key == "statusTimestampAfter",
                       do: "julianday(" <> col <> ")>=julianday(?)",
                       else: col <> "=?"
                     )
                   ], args ++ [p[key]]},
              else: {clauses, args}
          end
        )

      state_sql =
        "CASE json_extract(t.record,'$.status') WHEN 'pending' THEN 'TASK_STATE_SUBMITTED' WHEN 'running' THEN 'TASK_STATE_WORKING' WHEN 'completed' THEN 'TASK_STATE_COMPLETED' WHEN 'interrupted' THEN CASE WHEN json_extract(t.record,'$.failure_reason') IN ('explicit_cancel','explicit_cancel_forced') THEN 'TASK_STATE_CANCELED' ELSE 'TASK_STATE_FAILED' END ELSE 'TASK_STATE_FAILED' END"

      from =
        " FROM a2a_tasks a JOIN turns t ON t.id=a.id WHERE " <>
          Enum.join(
            ["1=1" | Enum.map(clauses, &String.replace(&1, "state=", state_sql <> "="))],
            " AND "
          )

      [[total]] = Store.rows("SELECT count(*)" <> from, args)

      {from, args} =
        case cursor do
          nil ->
            {from, args}

          [ts, id] ->
            {from <> " AND (a.updated_at < ? OR (a.updated_at = ? AND a.id < ?))",
             args ++ [ts, ts, id]}
        end

      size = p["pageSize"] || 50

      rows =
        Store.rows(
          "SELECT a.id,a.updated_at" <> from <> " ORDER BY a.updated_at DESC,a.id DESC LIMIT ?",
          args ++ [size + 1]
        )

      page = Enum.take(rows, size)

      next =
        if length(rows) > size do
          [id, ts] = List.last(page)
          Jason.encode!([fingerprint, ts, id]) |> Base.url_encode64(padding: false)
        else
          ""
        end

      tasks =
        Enum.map(page, fn [id, _] ->
          {task, _} = snapshot(id)
          task = history(task, p["historyLength"])
          if p["includeArtifacts"], do: task, else: Map.delete(task, "artifacts")
        end)

      {:ok,
       %{"tasks" => tasks, "nextPageToken" => next, "pageSize" => size, "totalSize" => total}}
    end
  end

  defp cursor(value, _) when value in [nil, ""], do: {:ok, nil}

  defp cursor(value, fingerprint) do
    with {:ok, bytes} <- Base.url_decode64(value, padding: false),
         {:ok, [^fingerprint, ts, id]} when is_binary(ts) and is_binary(id) <- Jason.decode(bytes),
         {:ok, _, _} <- DateTime.from_iso8601(ts) do
      {:ok, [ts, id]}
    else
      _ -> {:error, {-32602, "invalid_page_token"}}
    end
  end
end
