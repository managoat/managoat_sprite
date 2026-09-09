defmodule ManaspritesDesktop.Shell do
  use GenServer
  alias ManaspritesDesktopWeb.Endpoint

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def report_live(name) do
    if System.get_env("ELIXIRKIT_PUBSUB") do
      ElixirKit.PubSub.broadcast(
        "shell",
        Jason.encode!(%{event: "live_connected", workspace: name})
      )
    end
  end

  @impl true
  def init(_) do
    {:ok, %{}, {:continue, :announce}}
  end

  @impl true
  def handle_continue(:announce, state) do
    if Endpoint.config(:server) do
      {:ok, {_, port}} = Endpoint.server_info(:http)
      url = "http://127.0.0.1:#{port}/launch?token=#{ManaspritesDesktop.Bootstrap.token()}"

      if System.get_env("ELIXIRKIT_PUBSUB"),
        do: ElixirKit.PubSub.broadcast("shell", Jason.encode!(%{event: "ready", url: url}))

      if path = System.get_env("MANASPRITES_DESKTOP_READY_FILE") do
        File.write!(path, Jason.encode!(%{url: url, pid: System.pid()}), [:write, :exclusive])
        File.chmod!(path, 0o600)
      end
    end

    {:noreply, state}
  end
end
