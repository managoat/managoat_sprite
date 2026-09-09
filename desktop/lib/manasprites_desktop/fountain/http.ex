defmodule ManaspritesDesktop.Fountain.HTTP do
  @moduledoc "Opt-in, bearer-authenticated Fountain host API."
  use Plug.Router
  alias ManaspritesDesktop.Fountain
  alias Fountain.{Accounts, Store}
  plug(:match)
  plug(:access)
  plug(:parse)
  plug(:dispatch)

  get("/health", do: json(conn, 200, %{"status" => "ok"}))

  get "/health/ready" do
    Store.query("SELECT 1")
    json(conn, 200, %{"status" => "ok", "checks" => %{"database" => "ok"}})
  end

  get("/api/auth/me", do: json(conn, 200, conn.assigns.account))

  get "/api/catalog" do
    json(conn, 200, %{
      "data" => %{
        "runtimes" => ["claude", "codex"],
        "models" => %{"claude" => [], "codex" => []},
        "model_providers" => ["anthropic", "openai"],
        "package_managers" => [],
        "sandbox_providers" => %{"default" => "sprites", "enabled" => ["sprites"]},
        "apps" => %{"conversations" => nil, "team" => nil},
        "avatar" => %{"bases" => [], "moods" => []},
        "first_request" => %{
          "curl" => "",
          "typescript" => "",
          "prompt" => "Hello",
          "placeholders" => []
        }
      }
    })
  end

  get "/api/openapi.json" do
    path = Application.app_dir(:manasprites_desktop, "priv/fountain/openapi.json")
    conn |> put_resp_content_type("application/json") |> send_resp(200, File.read!(path))
  end

  get("/api/auth/api-keys", do: collection(conn, "key"))

  post "/api/auth/api-keys" do
    result =
      Store.transaction(fn ->
        Fountain.fields!(conn.body_params, ~w(name scopes))
        Fountain.text!(conn.body_params["name"], "name", 200)
        if conn.body_params["scopes"] not in [nil, ["*"]], do: Store.abort("unsupported_scopes")
        if length(Store.list(owner(conn), "key")) >= 1000, do: Store.abort("resource_limit", 429)
        Accounts.mint(owner(conn), conn.body_params["name"])
      end)

    respond(conn, result, 201, false)
  end

  delete("/api/auth/api-keys/:id", do: removed(conn, "key", id))
  get("/api/conversations", do: collection(conn, "conversation"))

  post("/api/conversations",
    do: respond(conn, Fountain.create_conversation(owner(conn), conn.body_params), 201)
  )

  get("/api/conversations/:id", do: resource(conn, "conversation", id))
  delete("/api/conversations/:id", do: removed(conn, "conversation", id))

  post "/api/conversations/:id/prompts" do
    case Fountain.prompt(owner(conn), id, conn.body_params) do
      {:ok, _} -> json(conn, 200, %{"status" => "queued"})
      error -> respond(conn, error)
    end
  end

  post "/api/conversations/:id/terminate" do
    case Fountain.terminate(owner(conn), id) do
      {:ok, _} -> terminated(conn, id, 20)
      error -> respond(conn, error)
    end
  end

  post "/api/conversations/:id/interrupt" do
    remote(
      conn,
      id,
      fn c ->
        Fountain.backend().request(
          owner(conn),
          c,
          :post,
          "/api/conversations/#{c["_remote_id"]}/interrupt"
        )
      end,
      204
    )
  end

  post "/api/conversations/:id/requests/:rid" do
    if is_binary(conn.body_params["option_id"]) and byte_size(rid) < 256 do
      remote(
        conn,
        id,
        fn c ->
          Fountain.backend().request(
            owner(conn),
            c,
            :post,
            "/api/conversations/#{c["_remote_id"]}/requests/#{URI.encode(rid, &URI.char_unreserved?/1)}",
            Map.take(conn.body_params, ["option_id"])
          )
        end,
        200
      )
    else
      error(conn, 422, "invalid_option")
    end
  end

  get "/api/conversations/:id/turns" do
    case Store.get(owner(conn), "conversation", id) do
      nil -> error(conn, 404, "not_found")
      c -> json(conn, 200, %{"data" => c["_turns"]})
    end
  end

  get "/api/conversations/:id/events" do
    if Store.get(owner(conn), "conversation", id) do
      with {:ok, cursor} <- number(conn.params["after"], 0, 9_007_199_254_740_991),
           {:ok, limit} when limit > 0 <- number(conn.params["limit"], 1000, 1000) do
        rows = Store.events(owner(conn), id, cursor, limit + 1)
        page = Enum.take(rows, limit) |> Enum.map(&event(&1, conn))

        json(conn, 200, %{
          "data" => page,
          "meta" => %{
            "limit" => limit,
            "has_more" => length(rows) > limit,
            "next_cursor" => (List.last(page) || %{})["id"]
          }
        })
      else
        _ -> error(conn, 422, "invalid_cursor")
      end
    else
      error(conn, 404, "not_found")
    end
  end

  get "/api/conversations/:id/stream" do
    if Store.get(owner(conn), "conversation", id),
      do: stream(conn, id),
      else: error(conn, 404, "not_found")
  end

  get("/api/events/stream", do: stream(conn, nil))

  get "/api/sandboxes/:id" do
    case sandbox(conn, id) do
      nil -> error(conn, 404, "not_found")
      c -> json(conn, 200, %{"data" => c["sandbox"]})
    end
  end

  get "/api/sandboxes/:id/file" do
    case sandbox(conn, id) do
      nil ->
        error(conn, 404, "not_found")

      c ->
        path = conn.params["path"]

        with true <- ManaspritesDesktop.Workspace.valid?(%{"action" => "file", "path" => path}),
             true <- is_binary(path) and path != "",
             {:ok, limit} when limit > 0 <- number(conn.params["max_bytes"], 131_072, 131_072),
             {:ok, file} <- Fountain.backend().file(owner(conn), c, path, limit) do
          json(conn, 200, %{"data" => file})
        else
          _ -> error(conn, 422, "file_unavailable")
        end
    end
  end

  get("/api/:collection" when collection in ["agents", "environments", "vaults"],
    do: collection(conn, kind(collection))
  )

  post("/api/:collection" when collection in ["agents", "environments", "vaults"],
    do: respond(conn, Fountain.create(owner(conn), kind(collection), conn.body_params), 201)
  )

  get("/api/:collection/:id" when collection in ["agents", "environments", "vaults"],
    do: resource(conn, kind(collection), id)
  )

  put("/api/:collection/:id" when collection in ["agents", "environments", "vaults"],
    do: respond(conn, Fountain.update(owner(conn), kind(collection), id, conn.body_params))
  )

  delete("/api/:collection/:id" when collection in ["agents", "environments", "vaults"],
    do: removed(conn, kind(collection), id)
  )

  match(_, do: error(conn, 404, "not_found"))

  defp terminated(conn, id, attempts) do
    c = Store.get(owner(conn), "conversation", id)

    cond do
      c["_phase"] == "terminated" ->
        send_resp(conn, 204, "")

      attempts == 0 ->
        error(conn, 503, "cleanup_pending")

      true ->
        Process.sleep(100)
        terminated(conn, id, attempts - 1)
    end
  end

  defp kind("agents"), do: "agent"
  defp kind("environments"), do: "environment"
  defp kind("vaults"), do: "vault"
  defp owner(conn), do: conn.assigns.account["id"]

  defp collection(conn, kind) do
    rows = Store.list(owner(conn), kind)

    rows =
      if kind == "conversation" do
        Enum.filter(rows, fn c ->
          (is_nil(conn.params["agent_id"]) or conn.params["agent_id"] == c["agent_id"]) and
            (is_nil(conn.params["status"]) or
               c["status"] in String.split(conn.params["status"], ","))
        end)
      else
        rows
      end

    json(conn, 200, %{"data" => Enum.map(rows, &Store.public/1)})
  end

  defp resource(conn, kind, id) do
    case Store.get(owner(conn), kind, id) do
      nil -> error(conn, 404, "not_found")
      value -> json(conn, 200, %{"data" => Store.public(value)})
    end
  end

  defp removed(conn, kind, id) do
    case Fountain.remove(owner(conn), kind, id) do
      {:ok, _} -> send_resp(conn, 204, "")
      failure -> respond(conn, failure)
    end
  end

  defp sandbox(conn, id),
    do: Store.list(owner(conn), "conversation") |> Enum.find(&(&1["sandbox_id"] == id))

  defp remote(conn, id, fun, status) do
    case Store.get(owner(conn), "conversation", id) do
      nil ->
        error(conn, 404, "not_found")

      %{"_remote_id" => _} = c ->
        case fun.(c) do
          {:ok, result} ->
            if status == 204, do: send_resp(conn, 204, ""), else: json(conn, status, result)

          {:error, {:http, code}} ->
            error(conn, code, "remote_request_failed")

          _ ->
            error(conn, 503, "remote_unavailable")
        end

      _ ->
        error(conn, 409, "conversation_not_ready")
    end
  end

  defp access(conn, _) do
    conn = fetch_query_params(conn)

    key =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> key] -> key
        _ -> nil
      end

    account = Accounts.authenticate(key)

    cond do
      conn.request_path in ["/health", "/health/ready"] ->
        conn

      is_nil(account) ->
        conn |> error(401, "unauthorized") |> halt()

      Enum.any?(conn.query_params, fn {_, v} -> not is_binary(v) end) ->
        conn |> error(422, "invalid_query") |> halt()

      true ->
        conn |> assign(:account, account) |> assign(:api_key, key)
    end
  end

  defp parse(%{method: method} = conn, _) when method in ~w(POST PUT PATCH) do
    case read_body(conn, length: 1_048_576, read_length: 1_048_576, read_timeout: 10_000) do
      {:ok, "", conn} ->
        %{conn | body_params: %{}}

      {:ok, bytes, conn} ->
        case Jason.decode(bytes) do
          {:ok, body} when is_map(body) -> %{conn | body_params: body}
          _ -> conn |> error(422, "invalid_json") |> halt()
        end

      {:more, _, conn} ->
        conn |> error(413, "request_too_large") |> halt()

      _ ->
        conn |> error(400, "request_failed") |> halt()
    end
  end

  defp parse(conn, _), do: conn

  defp stream(conn, id) do
    with {:ok, cursor} <-
           number(List.first(get_req_header(conn, "last-event-id")), 0, 9_007_199_254_740_991) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("x-accel-buffering", "no")
        |> send_chunked(200)

      case chunk(conn, ": connected\n\n") do
        {:ok, conn} -> tail(conn, id, cursor, clock(), clock())
        _ -> conn
      end
    else
      _ -> error(conn, 422, "invalid_cursor")
    end
  end

  defp tail(conn, id, cursor, activity, heartbeat) do
    rows = Store.events(owner(conn), id, cursor, 100)

    cond do
      is_nil(Accounts.authenticate(conn.assigns.api_key)) ->
        conn

      id && is_nil(Store.get(owner(conn), "conversation", id)) ->
        conn

      rows != [] ->
        Enum.reduce_while(rows, {:ok, conn}, fn row, {:ok, acc} ->
          row = event(row, conn)

          case chunk(
                 acc,
                 "id: #{row["id"]}\nevent: #{row["kind"]}\ndata: #{Jason.encode!(row)}\n\n"
               ) do
            {:ok, acc} -> {:cont, {:ok, acc}}
            _ -> {:halt, :closed}
          end
        end)
        |> case do
          {:ok, conn} -> tail(conn, id, List.last(rows)["id"], clock(), heartbeat)
          :closed -> conn
        end

      conn.params["wait"] == "false" or clock() - activity > 60_000 ->
        conn

      clock() - heartbeat >= 15_000 ->
        case chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} -> tail(conn, id, cursor, activity, clock())
          _ -> conn
        end

      true ->
        Process.sleep(100)
        tail(conn, id, cursor, activity, heartbeat)
    end
  end

  defp event(row, conn),
    do: if(conn.params["blocks"] in ~w(true 1), do: row, else: Map.delete(row, "blocks"))

  defp clock, do: System.monotonic_time(:millisecond)
  defp number(nil, default, _), do: {:ok, default}

  defp number(value, _, max) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 and n <= max -> {:ok, n}
      _ -> :error
    end
  end

  defp number(_, _, _), do: :error
  defp respond(conn, result, status \\ 200, envelope \\ true)

  defp respond(conn, {:ok, value}, status, envelope),
    do: json(conn, status, if(envelope, do: %{"data" => value}, else: value))

  defp respond(conn, {:error, {status, code}}, _, _), do: error(conn, status, code)

  defp respond(conn, {:error, {status, code, fields}}, _, _),
    do: json(conn, status, %{"error" => code, "errors" => fields})

  defp error(conn, status, code), do: json(conn, status, %{"error" => code})

  defp json(conn, status, value),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(value))
end
