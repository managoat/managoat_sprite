defmodule Managoat.Sprite.A2A.HTTP do
  @moduledoc "A2A 1.0 JSON-RPC binding; HTTP clients never own execution."
  import Plug.Conn
  alias Managoat.Sprite.{Engine, Store}
  alias Managoat.Sprite.A2A.{Card, Projection, Validation}
  @methods ~w(SendMessage SendStreamingMessage GetTask ListTasks CancelTask SubscribeToTask)

  def call(conn) do
    r = conn.body_params
    id = if is_map(r), do: r["id"]

    cond do
      not Card.enabled?() ->
        json(conn, 404, %{error: "not_found"})

      not valid_request?(r) ->
        error(conn, nil, -32600, "invalid_request")

      not version?(get_req_header(conn, "a2a-version")) ->
        error(conn, id, -32009, "version_not_supported")

      not Card.available?() ->
        error(conn, id, -32004, "configuration_needed")

      r["method"] in ~w(CreateTaskPushNotificationConfig GetTaskPushNotificationConfig ListTaskPushNotificationConfigs DeleteTaskPushNotificationConfig) ->
        error(conn, id, -32003, "push_notifications_not_supported")

      r["method"] == "GetExtendedAgentCard" ->
        error(conn, id, -32004, "extended_card_not_supported")

      r["method"] not in @methods ->
        error(conn, id, -32601, "method_not_found")

      true ->
        with :ok <- Validation.params(r["method"], Map.get(r, "params", %{})),
             {:ok, result} <- dispatch(r["method"], Map.get(r, "params", %{})) do
          respond(conn, id, result)
        else
          {:error, {code, reason}} -> error(conn, id, code, reason)
        end
    end
  end

  defp valid_request?(%{"jsonrpc" => "2.0", "id" => id, "method" => method}),
    do: (is_binary(id) or is_integer(id) or is_nil(id)) and is_binary(method)

  defp valid_request?(_), do: false
  defp version?([v]), do: Regex.match?(~r/\A1\.0(?:\.[0-9]+)?\z/, v)
  defp version?(_), do: false

  defp dispatch(method, p) when method in ~w(SendMessage SendStreamingMessage) do
    m = p["message"]

    with :ok <- message_target(m),
         attrs = %{
           "prompt" => Enum.map_join(m["parts"], "\n", & &1["text"]),
           "a2a_message_id" => m["messageId"],
           "a2a_message" => m
         },
         {:ok, result} <- admission(m["contextId"], attrs, m["messageId"]),
         {:ok, task} <- task(result["task_id"]) do
      history = get_in(p, ["configuration", "historyLength"])

      cond do
        method == "SendStreamingMessage" ->
          {:ok, {:stream, task, history}}

        get_in(p, ["configuration", "returnImmediately"]) == true ->
          {:ok, %{"task" => Projection.history(task, history)}}

        true ->
          with {:ok, task} <- await_terminal(task),
               do: {:ok, %{"task" => Projection.history(task, history)}}
      end
    end
  end

  defp dispatch("GetTask", p) do
    with {:ok, task} <- task(p["id"]), do: {:ok, Projection.history(task, p["historyLength"])}
  end

  defp dispatch("ListTasks", p), do: Store.call({:a2a_list, p})

  defp dispatch("CancelTask", p) do
    with {:ok, task} <- task(p["id"]),
         :ok <- cancel(task),
         {:ok, task} <- await_terminal(task, clock() + 15_000) do
      if task["status"]["state"] == "TASK_STATE_CANCELED",
        do: {:ok, task},
        else: {:error, {-32002, "task_not_cancelable"}}
    end
  end

  defp dispatch("SubscribeToTask", p) do
    with {:ok, task} <- task(p["id"]) do
      if Projection.terminal?(task),
        do: {:error, {-32004, "task_is_terminal"}},
        else: {:ok, {:stream, task, nil}}
    end
  end

  defp message_target(%{"taskId" => tid} = m) do
    with {:ok, task} <- task(tid) do
      cond do
        m["contextId"] && m["contextId"] != task["contextId"] ->
          {:error, {-32602, "task_context_mismatch"}}

        Projection.terminal?(task) ->
          {:error, {-32004, "task_is_terminal"}}

        true ->
          {:error, {-32004, "task_does_not_accept_messages"}}
      end
    end
  end

  defp message_target(_), do: :ok

  defp admission(cid, attrs, mid) do
    case Engine.admit(cid, attrs, {:a2a, mid}) do
      {:ok, result} ->
        {:ok, result}

      {:error, {status, reason}} ->
        code =
          cond do
            reason == "idempotency_conflict" -> -32602
            status == 404 -> -32602
            status == 410 -> -32001
            status == 503 -> -32603
            true -> -32004
          end

        {:error, {code, reason}}
    end
  end

  defp cancel(task) do
    case Engine.interrupt_task(task["id"]) do
      :ok -> :ok
      _ -> {:error, {-32002, "task_not_cancelable"}}
    end
  end

  defp task(id) do
    case Store.call({:a2a_snapshot, id}) do
      {task, _} -> {:ok, task}
      nil -> {:error, {-32001, "task_not_found"}}
    end
  end

  defp await_terminal(task, deadline \\ nil) do
    cond do
      Projection.terminal?(task) ->
        {:ok, task}

      deadline != nil and clock() >= deadline ->
        {:error, {-32603, "cleanup_pending"}}

      true ->
        Process.sleep(100)
        with {:ok, latest} <- task(task["id"]), do: await_terminal(latest, deadline)
    end
  end

  defp respond(conn, id, {:stream, task, history}) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    # Re-read after admission: snapshot and cursor come from the same transaction.
    case Store.call({:a2a_snapshot, task["id"]}) do
      {latest, cursor} ->
        case frame(conn, id, %{"task" => Projection.history(latest, history)}, cursor) do
          {:ok, conn} ->
            if Projection.terminal?(latest),
              do: conn,
              else: tail(conn, id, latest, cursor, clock(), clock())

          _ ->
            conn
        end

      nil ->
        conn
    end
  end

  defp respond(conn, id, result), do: json(conn, 200, %{jsonrpc: "2.0", id: id, result: result})

  defp tail(conn, id, previous, cursor, last_change, heartbeat) do
    Process.sleep(200)

    case Store.call({:a2a_snapshot, previous["id"]}) do
      nil ->
        case chunk(
               conn,
               "data: " <> Jason.encode!(error_body(id, -32001, "task_not_found")) <> "\n\n"
             ) do
          {:ok, conn} -> conn
          _ -> conn
        end

      {task, next} when next != cursor ->
        updates = updates(previous, task)

        result =
          Enum.reduce_while(updates, {:ok, conn}, fn update, {:ok, conn} ->
            case frame(conn, id, update, next) do
              {:ok, conn} -> {:cont, {:ok, conn}}
              error -> {:halt, error}
            end
          end)

        case result do
          {:ok, conn} ->
            if Projection.terminal?(task),
              do: conn,
              else: tail(conn, id, task, next, clock(), heartbeat)

          _ ->
            conn
        end

      _ ->
        cond do
          clock() - last_change >= 60_000 ->
            conn

          clock() - heartbeat >= 15_000 ->
            case chunk(conn, ": heartbeat\n\n") do
              {:ok, conn} -> tail(conn, id, previous, cursor, last_change, clock())
              _ -> conn
            end

          true ->
            tail(conn, id, previous, cursor, last_change, heartbeat)
        end
    end
  end

  defp updates(previous, task) do
    base = %{"taskId" => task["id"], "contextId" => task["contextId"]}

    artifacts =
      if task["artifacts"] != previous["artifacts"] or Projection.terminal?(task) do
        Enum.map(task["artifacts"], fn artifact ->
          %{
            "artifactUpdate" =>
              Map.merge(base, %{
                "artifact" => artifact,
                "append" => false,
                "lastChunk" => Projection.terminal?(task)
              })
          }
        end)
      else
        []
      end

    artifacts ++ [%{"statusUpdate" => Map.put(base, "status", task["status"])}]
  end

  defp frame(conn, id, result, cursor),
    do:
      chunk(
        conn,
        "id: #{cursor}\ndata: " <>
          Jason.encode!(%{jsonrpc: "2.0", id: id, result: result}) <> "\n\n"
      )

  defp clock, do: System.monotonic_time(:millisecond)

  def error(conn, id, code, reason), do: json(conn, 200, error_body(id, code, reason))

  defp error_body(id, code, reason) do
    message =
      case code do
        -32700 -> "Parse error"
        -32600 -> "Invalid Request"
        -32601 -> "Method not found"
        -32602 -> "Invalid params"
        -32603 -> "Internal error"
        -32001 -> "Task not found"
        -32002 -> "Task not cancelable"
        -32003 -> "Push notifications not supported"
        -32004 -> "Unsupported operation"
        -32005 -> "Content type not supported"
        -32009 -> "Version not supported"
      end

    %{jsonrpc: "2.0", id: id, error: %{code: code, message: message, data: %{reason: reason}}}
  end

  defp json(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
end
