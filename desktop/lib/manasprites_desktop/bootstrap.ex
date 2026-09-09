defmodule ManaspritesDesktop.Bootstrap do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    repo = ManaspritesDesktop.Repo
    # Hold SQLite's process-wide exclusive lock for this Repo connection's life.
    Ecto.Adapters.SQL.query!(repo, "PRAGMA locking_mode=EXCLUSIVE", [])

    Ecto.Migrator.run(
      repo,
      [
        {20_260_908_000_000, ManaspritesDesktop.Repo.Migrations.CreateFleet},
        {20_260_908_010_000, ManaspritesDesktop.Repo.Migrations.LocalConnections},
        {20_260_908_020_000, ManaspritesDesktop.Repo.Migrations.PlatformJobs},
        {20_260_908_030_000, ManaspritesDesktop.Repo.Migrations.PrivateConnections},
        {20_260_908_040_000, ManaspritesDesktop.Repo.Migrations.FountainAPI}
      ],
      :up,
      all: true,
      log: false
    )

    root = Application.fetch_env!(:manasprites_desktop, :root)
    for file <- Path.wildcard(Path.join(root, "fleet.sqlite3*")), do: File.chmod!(file, 0o600)
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    :persistent_term.put({__MODULE__, :token}, token)
    {:ok, %{}}
  end

  def token, do: :persistent_term.get({__MODULE__, :token})
end
