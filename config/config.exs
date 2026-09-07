import Config
config :managoat_sprite, ecto_repos: [Managoat.Sprite.Repo]

config :managoat_sprite, Managoat.Sprite.Repo,
  pool_size: 1,
  journal_mode: :wal,
  synchronous: :full,
  busy_timeout: 5_000,
  foreign_keys: :on

config :managoat_sandbox, adapters: %{local: Managoat.Sprite.Sandbox.Local}
config :logger, level: :warning

if config_env() == :test do
  config :managoat_sprite, boot: false
end
