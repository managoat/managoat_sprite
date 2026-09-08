import Config

config :manasprites_desktop, ecto_repos: [ManaspritesDesktop.Repo]

config :manasprites_desktop, ManaspritesDesktop.Repo,
  pool_size: 1,
  locking_mode: :exclusive,
  journal_mode: :wal,
  synchronous: :full,
  busy_timeout: 2_000,
  foreign_keys: :on

config :manasprites_desktop, ManaspritesDesktopWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: ManaspritesDesktopWeb.ErrorHTML], layout: false],
  pubsub_server: ManaspritesDesktop.PubSub,
  live_view: [signing_salt: "manasprites-live"]

config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["key", "token", "secret", "password", "prompt"]
config :logger, level: :warning

if config_env() == :test do
  config :manasprites_desktop, boot: false
end
