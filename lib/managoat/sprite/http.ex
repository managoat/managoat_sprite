defmodule Managoat.Sprite.HTTP do
  @moduledoc "Fountain conversations v1 subset, with authenticated durable SSE."
  use Plug.Router
  alias Managoat.Sprite.{Config, Engine, Store}
  plug(:match)
  plug(:access)
  plug(:body)
  plug(:dispatch)

  get("/healthz", do: json(conn, 200, %{ok: true}))

  get "/readyz" do
    ready = Engine.ready?() and Engine.runtime().ready?()
    json(conn, if(ready, do: 200, else: 503), %{ready: ready, inference_verified: false})
  end

  get "/api/openapi.json" do
    path = Application.app_dir(:managoat_sprite, "priv/openapi.json")
    conn |> put_resp_content_type("application/json") |> send_resp(200, File.read!(path))
  end

  get "/api/capabilities" do
    json(conn, 200, %{
      contract: "fountain-conversations-v1",
      runtime: Config.get()["runtime"],
      features: ~w(text conversations turns events sse permissions interrupt idempotency),
      concurrent_turns: 1,
      shared_workspace: true,
      authentication: "bearer",
      recovery: "interrupt_then_resume"
    })
  end

  get("/api/agents", do: json(conn, 200, %{data: [agent()]}))
  get("/api/agents/default", do: json(conn, 200, %{data: agent()}))

  get "/api/conversations" do
    statuses = String.split(conn.params["status"] || "", ",", trim: true)

    cond do
      Enum.any?(statuses, &(&1 not in ~w(pending running idle failed terminated))) ->
        error(conn, 400, "invalid_status")

      Map.keys(conn.params) -- ~w(status agent_id) != [] ->
        error(conn, 422, "unsupported_feature")

      true ->
        conversations =
          Store.call(:conversations)
          |> Enum.filter(fn c ->
            (statuses == [] or c["status"] in statuses) and
              (is_nil(conn.params["agent_id"]) or c["agent_id"] == conn.params["agent_id"])
          end)

        json(conn, 200, %{data: conversations})
    end
  end

  post "/api/conversations" do
    with :ok <- valid_prompt(conn.body_params, true),
         {:ok, key} <- idempotency_key(conn),
         {:ok, response} <- Engine.admit(nil, conn.body_params, key) do
      json(conn, 201, response)
    else
      e -> failure(conn, e)
    end
  end

  get "/api/conversations/:id" do
    case Store.call({:get, id}) do
      nil -> error(conn, 404, "not_found")
      c -> json(conn, 200, %{data: c})
    end
  end

  post "/api/conversations/:id/prompts" do
    with :ok <- valid_prompt(conn.body_params, false),
         {:ok, key} <- idempotency_key(conn),
         {:ok, response} <- Engine.admit(id, conn.body_params, key) do
      json(conn, 200, response)
    else
      e -> failure(conn, e)
    end
  end

  get "/api/conversations/:id/turns" do
    if Store.call({:get, id}),
      do: json(conn, 200, %{data: Store.call({:turns, id})}),
      else: error(conn, 404, "not_found")
  end

  get "/api/conversations/:id/events" do
    with :ok <- exists(id),
         {:ok, after_id} <- integer(conn.params["after"], 0),
         {:ok, limit} <- integer(conn.params["limit"], 1000),
         true <- limit > 0 and limit <= 1000 do
      rows = Store.call({:events, id, after_id, limit + 1, streams(conn)})
      page = Enum.take(rows, limit)

      json(conn, 200, %{
        data: Enum.map(page, &event_json(&1, conn, false)),
        meta: %{
          limit: limit,
          has_more: length(rows) > limit,
          next_cursor: (List.last(page) || %{})["id"]
        }
      })
    else
      false -> error(conn, 422, "invalid_limit")
      e -> failure(conn, e)
    end
  end

  get "/api/conversations/:id/stream" do
    with :ok <- exists(id),
         {:ok, cursor} <- integer(List.first(get_req_header(conn, "last-event-id")), 0) do
      stream(conn, id, cursor)
    else
      e -> failure(conn, e)
    end
  end

  get "/api/events/stream" do
    with {:ok, cursor} <-
           integer(List.first(get_req_header(conn, "last-event-id")), Store.call(:latest)) do
      stream(conn, nil, cursor)
    else
      e -> failure(conn, e)
    end
  end

  post "/api/conversations/:id/interrupt" do
    with :ok <- exists(id), :ok <- Engine.interrupt(id) do
      send_resp(conn, 204, "")
    else
      e -> failure(conn, e)
    end
  end

  post "/api/conversations/:id/terminate" do
    with :ok <- exists(id), :ok <- Engine.terminate_conversation(id) do
      send_resp(conn, 204, "")
    else
      e -> failure(conn, e)
    end
  end

  delete "/api/conversations/:id" do
    with :ok <- exists(id), :ok <- Engine.terminate_conversation(id, true) do
      send_resp(conn, 204, "")
    else
      e -> failure(conn, e)
    end
  end

  post "/api/conversations/:id/requests/:rid" do
    option = conn.body_params["option_id"]

    if is_binary(option) and option != "" do
      with :ok <- exists(id), :ok <- Engine.answer(id, rid, option) do
        json(conn, 200, %{ok: true})
      else
        e -> failure(conn, e)
      end
    else
      error(conn, 422, "option_id_required")
    end
  end

  match(_, do: error(conn, 404, "not_found"))

  defp access(conn, _) do
    conn = fetch_query_params(conn)
    origin = List.first(get_req_header(conn, "origin"))
    allowed = origin in Config.get()["cors_origins"]

    conn =
      if allowed do
        conn
        |> put_resp_header("access-control-allow-origin", origin)
        |> put_resp_header("vary", "Origin")
        |> put_resp_header(
          "access-control-allow-headers",
          "Authorization, Content-Type, Last-Event-ID, Idempotency-Key"
        )
        |> put_resp_header("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")
      else
        conn
      end

    cond do
      conn.method == "OPTIONS" and allowed ->
        conn |> send_resp(204, "") |> halt()

      conn.method == "OPTIONS" ->
        conn |> error(403, "origin_denied") |> halt()

      conn.request_path == "/healthz" ->
        conn

      Enum.any?(conn.query_params, fn {_, value} -> not is_binary(value) end) ->
        conn |> error(422, "invalid_query") |> halt()

      get_req_header(conn, "x-fountain-parent-conversation-id") != [] or
          get_req_header(conn, "x-aod-parent-conversation-id") != [] ->
        conn |> error(422, "unsupported_feature") |> halt()

      authorized?(conn) ->
        conn

      true ->
        conn |> error(401, "unauthorized") |> halt()
    end
  end

  defp authorized?(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> key] -> Store.call({:auth, key})
      _ -> false
    end
  end

  defp body(%{method: method} = conn, _) when method in ["POST", "PUT", "PATCH"] do
    case read_body(conn,
           length: Config.get()["max_request_bytes"],
           read_length: Config.get()["max_request_bytes"],
           read_timeout: 10_000
         ) do
      {:more, _, conn} ->
        conn |> error(413, "request_too_large") |> halt()

      {:ok, "", conn} ->
        %{conn | body_params: %{}}

      {:ok, bytes, conn} ->
        case Jason.decode(bytes) do
          {:ok, map} when is_map(map) -> %{conn | body_params: map}
          _ -> conn |> error(422, "invalid_json") |> halt()
        end

      _ ->
        conn |> error(400, "request_failed") |> halt()
    end
  end

  defp body(conn, _), do: conn

  defp valid_prompt(attrs, create?) do
    allowed = if create?, do: ~w(agent_id prompt title permission_policy), else: ~w(prompt)
    policy = attrs["permission_policy"]

    cond do
      Map.keys(attrs) -- allowed != [] ->
        {:error, {422, "unsupported_feature"}}

      attrs["agent_id"] not in [nil, "default"] ->
        {:error, {404, "not_found"}}

      not is_binary(attrs["prompt"]) or String.trim(attrs["prompt"]) == "" ->
        {:error, {422, "prompt_required"}}

      not is_nil(attrs["title"]) and not is_binary(attrs["title"]) ->
        {:error, {422, "invalid_title"}}

      policy &&
          (not is_map(policy) or
             not Enum.all?(policy, fn {_, v} -> v in ~w(auto_allow ask auto_deny) end)) ->
        {:error, {422, "invalid_policy"}}

      policy && Managoat.ACP.Permissions.check_narrows(Config.get()["permissions"], policy) != :ok ->
        {:error, {422, "policy_widening"}}

      true ->
        :ok
    end
  end

  defp agent,
    do: %{
      id: "default",
      name: Config.get()["name"],
      runtime: Config.get()["runtime"],
      model: Config.get()["model"],
      description: "Agent on this computer"
    }

  defp exists(id), do: if(Store.call({:get, id}), do: :ok, else: {:error, {404, "not_found"}})
  defp integer(nil, default), do: {:ok, default}

  defp integer(value, _) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 and n <= 9_007_199_254_740_991 -> {:ok, n}
      _ -> {:error, {422, "invalid_cursor"}}
    end
  end

  defp integer(_, _), do: {:error, {422, "invalid_cursor"}}

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [] -> {:ok, nil}
      [key] when byte_size(key) > 0 and byte_size(key) <= 256 -> {:ok, key}
      _ -> {:error, {422, "invalid_idempotency_key"}}
    end
  end

  defp streams(conn), do: String.split(conn.params["streams"] || "", ",", trim: true)

  defp event_json(e, conn, global?) do
    data = if global?, do: e, else: Map.delete(e, "conversation_id")

    if conn.params["blocks"] in ["true", "1"] do
      blocks =
        if e["kind"] == "output", do: Managoat.ACP.Blocks.from_line(e["data"] || ""), else: []

      blocks =
        Enum.map(blocks, fn block ->
          Map.new(block, fn
            {:error?, v} -> {"error", v}
            {k, v} -> {to_string(k), v}
          end)
        end)

      Map.put(data, "blocks", blocks)
    else
      data
    end
  end

  defp stream(conn, id, cursor) do
    conn =
      conn
      |> assign(:revision, Store.call(:revision))
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    case chunk(conn, ": connected\n\n") do
      {:ok, conn} -> tail(conn, id, cursor, clock(), clock())
      _ -> conn
    end
  end

  defp tail(conn, id, cursor, last_event, last_heartbeat) do
    revision = if is_nil(id), do: Store.call(:revision), else: conn.assigns.revision

    result =
      if revision != conn.assigns.revision do
        chunk(conn, "event: conversations\ndata: {\"reason\":\"changed\"}\n\n")
      else
        {:ok, conn}
      end

    case result do
      {:ok, conn} ->
        tail_events(assign(conn, :revision, revision), id, cursor, last_event, last_heartbeat)

      _ ->
        conn
    end
  end

  defp tail_events(conn, id, cursor, last_event, last_heartbeat) do
    rows = Store.call({:events, id, cursor, 1000, streams(conn)})

    result =
      Enum.reduce_while(rows, {:ok, conn, cursor}, fn e, {:ok, c, _} ->
        bytes =
          "id: #{e["id"]}\nevent: #{e["kind"]}\ndata: #{Jason.encode!(event_json(e, conn, is_nil(id)))}\n\n"

        case chunk(c, bytes) do
          {:ok, c} -> {:cont, {:ok, c, e["id"]}}
          _ -> {:halt, :closed}
        end
      end)

    case result do
      :closed ->
        conn

      {:ok, conn, cursor} ->
        last_event = if rows == [], do: last_event, else: clock()

        cond do
          length(rows) == 1000 ->
            tail(conn, id, cursor, last_event, last_heartbeat)

          conn.params["wait"] == "false" or clock() - last_event >= 60_000 ->
            conn

          clock() - last_heartbeat >= 15_000 ->
            case chunk(conn, ": heartbeat\n\n") do
              {:ok, c} -> tail(c, id, cursor, last_event, clock())
              _ -> conn
            end

          true ->
            Process.sleep(200)
            tail(conn, id, cursor, last_event, last_heartbeat)
        end
    end
  end

  defp clock, do: System.monotonic_time(:millisecond)
  defp failure(conn, {:error, {status, code}}), do: error(conn, status, code)
  defp failure(conn, _), do: error(conn, 503, "unavailable")

  defp error(conn, status, code),
    do: json(conn, status, %{error: code, message: String.replace(code, "_", " ")})

  defp json(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
end
