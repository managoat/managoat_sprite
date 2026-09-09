defmodule ManaspritesDesktop.PlatformFixture do
  @moduledoc false
  import Plug.Conn
  def init(state), do: state

  def call(conn, state) do
    conn = fetch_query_params(conn)
    owner = Agent.get(state, & &1.owner)
    # Assertions can inspect public request metadata without ever logging stdin.
    send(owner, {:platform_request, conn.method, conn.request_path})

    if get_req_header(conn, "authorization") != ["Bearer test-org/token/synthetic-secret"] do
      json(conn, 401, %{})
    else
      route(conn, state)
    end
  end

  defp route(%{request_path: "/v1/sprites", method: "GET"} = conn, state) do
    values = Agent.get(state, & &1.catalogue)

    if conn.params["continuation_token"] do
      json(conn, 200, %{"sprites" => Enum.drop(values, 1), "has_more" => false})
    else
      json(conn, 200, %{
        "sprites" => Enum.take(values, 1),
        "has_more" => length(values) > 1,
        "next_continuation_token" => "second page+/="
      })
    end
  end

  defp route(%{request_path: "/v1/sprites", method: "POST"} = conn, state) do
    {:ok, raw, conn} = read_body(conn)
    body = Jason.decode!(raw)

    result =
      Agent.get_and_update(state, fn s ->
        info = %{
          "name" => body["name"],
          "organization" => "test-org",
          "id" => Ecto.UUID.generate(),
          "labels" => body["labels"],
          "url_settings" => body["url_settings"],
          "url" => s.service_url
        }

        {s.lose_create,
         %{
           s
           | sprites: Map.put(s.sprites, body["name"], info),
             creates: s.creates + 1,
             lose_create: false
         }}
      end)

    json(conn, if(result, do: 503, else: 201), %{})
  end

  defp route(conn, state) do
    case {conn.method, String.split(conn.request_path, "/", trim: true)} do
      {"GET", ["v1", "sprites", name]} ->
        case Agent.get(state, & &1.sprites[name]) do
          nil -> json(conn, 404, %{})
          info -> json(conn, 200, info)
        end

      {"DELETE", ["v1", "sprites", name]} ->
        Agent.update(state, &%{&1 | sprites: Map.delete(&1.sprites, name)})
        send_resp(conn, 204, "")

      {"PUT", ["v1", "sprites", name]} ->
        {:ok, raw, conn} = read_body(conn)
        body = Jason.decode!(raw)
        Agent.update(state, &put_in(&1, [:sprites, name, "url_settings"], body["url_settings"]))
        json(conn, 200, %{})

      {"GET", ["v1", "sprites", _, "exec"]} ->
        args =
          URI.query_decoder(conn.query_string)
          |> Enum.filter(&(elem(&1, 0) == "cmd"))
          |> Enum.map(&elem(&1, 1))

        WebSockAdapter.upgrade(
          conn,
          ManaspritesDesktop.PlatformFixture.Socket,
          %{args: args, fixture: state},
          timeout: 30_000
        )

      {"GET", ["v1", "sprites", _, "proxy"]} ->
        WebSockAdapter.upgrade(conn, ManaspritesDesktop.PlatformFixture.Proxy, %{fixture: state},
          timeout: 30_000
        )

      _ ->
        json(conn, 404, %{})
    end
  end

  defp json(conn, status, data),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(data))
end

defmodule ManaspritesDesktop.PlatformFixture.Proxy do
  @moduledoc false
  @behaviour WebSock
  def init(s), do: {:ok, Map.merge(s, %{socket: nil, owner: Agent.get(s.fixture, & &1.owner)})}

  def handle_in({raw, [opcode: :text]}, %{socket: nil} = s) do
    %{"host" => "localhost", "port" => port} = Jason.decode!(raw)
    target = Agent.get(s.fixture, &URI.parse(&1.service_url))
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", target.port, [:binary, active: :once])
    send(s.owner, {:proxy_open, self(), port})
    {:push, {:text, ~s({"status":"connected"})}, %{s | socket: socket}}
  end

  def handle_in({data, [opcode: :binary]}, s) do
    :ok = :gen_tcp.send(s.socket, data)
    {:ok, s}
  end

  def handle_info({:tcp, socket, data}, s) do
    :inet.setopts(socket, active: :once)
    {:push, {:binary, data}, s}
  end

  def handle_info({:tcp_closed, _}, s), do: {:stop, :normal, s}
  def handle_info({:tcp_error, _, _}, s), do: {:stop, :normal, s}

  def terminate(_, s) do
    if s.socket, do: :gen_tcp.close(s.socket)
    send(s.owner, {:proxy_closed, self()})
    :ok
  end
end

defmodule ManaspritesDesktop.PlatformFixture.Socket do
  @moduledoc false
  @behaviour WebSock
  def init(state), do: {:ok, Map.merge(state, %{input: "", process: nil})}

  def handle_in({<<0, data::binary>>, [opcode: :binary]}, s),
    do: {:ok, %{s | input: s.input <> data}}

  def handle_in({<<4>>, [opcode: :binary]}, s) do
    [command | args] = s.args

    emulate = Agent.get(s.fixture, & &1.emulate_install)

    case {emulate, Jason.decode(s.input)} do
      {true, {:ok, %{"source" => _, "config" => _} = payload}} ->
        # Model the installed Sprite boundary. The independent transport tests
        # below run actual subprocesses; root installer tests execute this setup
        # helper with real Git/bootstrap children and durable remote state.
        if payload["client_key"] do
          Managoat.Sprite.Store.call({:key, payload["client_key"]})

          if Agent.get(s.fixture, &Map.get(&1, :write_installed_config, false)) do
            config_root =
              Path.join(Agent.get(s.fixture, & &1.home), ".local/share/managoat/config")

            Managoat.Sprite.Config.private_write!(
              Path.join(config_root, "client.key"),
              payload["client_key"]
            )

            Managoat.Sprite.Config.private_write!(
              Path.join(config_root, "config.json"),
              Jason.encode!(Managoat.Sprite.Config.get())
            )
          end
        end

        owner = Agent.get(s.fixture, & &1.owner)
        send(owner, {:setup_received, Map.keys(payload["env"] || %{})})
        {:push, [{:binary, <<1, ~s({"ok":true,"ready":true})::binary>>}, {:binary, <<3, 0>>}], s}

      _ ->
        held = Agent.get(s.fixture, &Map.get(&1, :hold_inspection, false))

        if held and match?({:ok, %{"action" => "file"}}, Jason.decode(s.input)) do
          send(Agent.get(s.fixture, & &1.owner), {:inspection_waiting, self()})
          {:ok, s}
        else
          execute(s, command, args)
        end
    end
  end

  def handle_in(_, s), do: {:ok, s}

  def handle_info(:release_inspection, s) do
    [command | args] = s.args
    execute(s, command, args)
  end

  def handle_info({:stdout, _, data}, s), do: {:push, {:binary, <<1, data::binary>>}, s}
  def handle_info({:stderr, _, data}, s), do: {:push, {:binary, <<2, data::binary>>}, s}
  def handle_info({:exit, _, code}, s), do: {:push, {:binary, <<3, code>>}, s}
  def handle_info(_, s), do: {:ok, s}

  defp execute(s, command, args) do
    {:ok, pid} =
      Managoat.Sprite.Execution.start(System.find_executable(command), args,
        env: [
          {"PATH", "/opt/homebrew/bin:/usr/bin:/bin"},
          {"HOME", Agent.get(s.fixture, & &1.home)}
        ]
      )

    :ok = Managoat.Sprite.Execution.write(pid, s.input)
    :ok = Managoat.Sprite.Execution.close_stdin(pid)
    send(Agent.get(s.fixture, & &1.owner), {:local_exec, pid})
    {:ok, %{s | process: pid}}
  end

  def terminate(_, s) do
    if s.process, do: Managoat.Sprite.Execution.stop(s.process)
    :ok
  end
end
