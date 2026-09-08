defmodule ManaspritesDesktop.Application do
  use Application

  @impl true
  def start(_, _) do
    children = if Application.get_env(:manasprites_desktop, :boot, true), do: children(), else: []
    Supervisor.start_link(children, strategy: :rest_for_one, name: ManaspritesDesktop.Supervisor)
  end

  def children do
    root = Application.fetch_env!(:manasprites_desktop, :root)
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)

    [
      {ManaspritesDesktop.Repo, database: Path.join(root, "fleet.sqlite3")},
      ManaspritesDesktop.Bootstrap,
      ManaspritesDesktop.Vault,
      {Phoenix.PubSub, name: ManaspritesDesktop.PubSub},
      {Registry, keys: :unique, name: ManaspritesDesktop.Connections},
      {Task.Supervisor, name: ManaspritesDesktop.Jobs},
      {DynamicSupervisor, strategy: :one_for_one, name: ManaspritesDesktop.ConnectionSupervisor},
      ManaspritesDesktop.Recovery,
      ManaspritesDesktop.Platform,
      {ElixirKit.PubSub,
       connect: System.get_env("ELIXIRKIT_PUBSUB") || :ignore, on_exit: &System.stop/0},
      ManaspritesDesktopWeb.Endpoint,
      ManaspritesDesktop.Shell
    ]
  end
end
