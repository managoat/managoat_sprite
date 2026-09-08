defmodule ManaspritesDesktop.PrivateProxy do
  @moduledoc "A single-request loopback relay, linked to its OTP job owner."
  use GenServer
  alias ManaspritesDesktop.PlatformClient
  @limit 20 * 1024 * 1024

  def with_url(token, name, port, callback) do
    with true <- PlatformClient.name?(name) and port in 1..65_535,
         {:ok, pid} <- GenServer.start_link(__MODULE__, {self(), token, name, port}) do
      try do
        callback.(GenServer.call(pid, :url))
      after
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal)
          catch
            :exit, _ -> :ok
          end
        end
      end
    else
      _ -> {:error, :connection_failed}
    end
  catch
    :exit, _ -> {:error, :connection_failed}
  end

  @impl true
  def init({caller, token, name, port}) do
    Process.monitor(caller)

    with {:ok, listener} <-
           :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: false]),
         {:ok, {_, local_port}} <- :inet.sockname(listener) do
      owner = self()

      acceptor =
        spawn_link(fn ->
          case :gen_tcp.accept(listener, 10_000) do
            {:ok, socket} ->
              :ok = :gen_tcp.controlling_process(socket, owner)
              send(owner, {:accepted, socket})

            _ ->
              send(owner, :expired)
          end
        end)

      Process.send_after(self(), :expired, 90_000)

      {:ok,
       %{
         listener: listener,
         acceptor: acceptor,
         local_port: local_port,
         token: token,
         name: name,
         port: port,
         socket: nil,
         gun: nil,
         stream: nil,
         phase: :accepting,
         bytes: 0
       }}
    else
      _ -> {:stop, :normal}
    end
  end

  @impl true
  def handle_call(:url, _, s), do: {:reply, "http://127.0.0.1:#{s.local_port}", s}

  @impl true
  def handle_info({:accepted, socket}, s) do
    :gen_tcp.close(s.listener)
    :inet.setopts(socket, send_timeout: 5_000, send_timeout_close: true)
    uri = URI.parse(PlatformClient.base_url())

    opts = %{protocols: [:http], retry: 0, connect_timeout: 10_000, domain_lookup_timeout: 10_000}

    opts =
      if uri.scheme == "https" do
        Map.merge(opts, %{
          transport: :tls,
          tls_opts: [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            depth: 5,
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
        })
      else
        opts
      end

    # Cleartext is allowed only for the local platform integration fixture.
    if uri.scheme == "https" or (uri.scheme == "http" and uri.host == "127.0.0.1") do
      case :gun.open(String.to_charlist(uri.host), uri.port, opts) do
        {:ok, gun} ->
          Process.monitor(gun)
          {:noreply, %{s | socket: socket, gun: gun, phase: :connecting}}

        _ ->
          {:stop, :normal, %{s | socket: socket}}
      end
    else
      {:stop, :normal, %{s | socket: socket}}
    end
  end

  def handle_info({:gun_up, gun, :http}, %{gun: gun} = s) do
    stream =
      :gun.ws_upgrade(
        gun,
        "/v1/sprites/#{s.name}/proxy",
        [{"authorization", "Bearer " <> s.token}],
        %{flow: 1, compress: false}
      )

    {:noreply, %{s | stream: stream, token: nil, phase: :upgrade}}
  end

  def handle_info({:gun_upgrade, gun, stream, ["websocket"], _}, %{gun: gun, stream: stream} = s) do
    :gun.ws_send(gun, stream, {:text, Jason.encode!(%{host: "localhost", port: s.port})})
    {:noreply, %{s | phase: :handshake}}
  end

  def handle_info(
        {:gun_ws, gun, stream, {:text, raw}},
        %{gun: gun, stream: stream, phase: :handshake} = s
      ) do
    if byte_size(raw) < 4096 and match?({:ok, %{"status" => "connected"}}, Jason.decode(raw)) do
      :inet.setopts(s.socket, active: :once)
      :gun.update_flow(gun, stream, 1)
      {:noreply, %{s | phase: :relay}}
    else
      {:stop, :normal, s}
    end
  end

  def handle_info({:tcp, socket, data}, %{socket: socket, phase: :relay} = s) do
    if s.bytes + byte_size(data) <= @limit do
      :gun.ws_send(s.gun, s.stream, {:binary, data})
      :inet.setopts(socket, active: :once)
      {:noreply, %{s | bytes: s.bytes + byte_size(data)}}
    else
      {:stop, :normal, s}
    end
  end

  def handle_info(
        {:gun_ws, gun, stream, {:binary, data}},
        %{gun: gun, stream: stream, phase: :relay} = s
      ) do
    if s.bytes + byte_size(data) <= @limit and :gen_tcp.send(s.socket, data) == :ok do
      :gun.update_flow(gun, stream, 1)
      {:noreply, %{s | bytes: s.bytes + byte_size(data)}}
    else
      {:stop, :normal, s}
    end
  end

  def handle_info(:expired, s), do: {:stop, :normal, s}
  def handle_info({:DOWN, _, :process, _, _}, s), do: {:stop, :normal, s}
  def handle_info({:tcp_closed, _}, s), do: {:stop, :normal, s}
  def handle_info({:tcp_error, _, _}, s), do: {:stop, :normal, s}
  def handle_info({:gun_down, _, _, _, _}, s), do: {:stop, :normal, s}
  def handle_info({:gun_error, _, _}, s), do: {:stop, :normal, s}
  def handle_info({:gun_error, _, _, _}, s), do: {:stop, :normal, s}
  def handle_info({:gun_response, _, _, _, _, _}, s), do: {:stop, :normal, s}
  def handle_info({:gun_ws, _, _, _}, s), do: {:stop, :normal, s}
  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_, s) do
    :gen_tcp.close(s.listener)
    if s.socket, do: :gen_tcp.close(s.socket)
    if s.gun, do: :gun.close(s.gun)
    if Process.alive?(s.acceptor), do: Process.exit(s.acceptor, :shutdown)
    :ok
  end

  @impl true
  def format_status(_), do: %{state: :redacted, message: :redacted, reason: :redacted}
end
