import Config

root =
  System.get_env("MANASPRITES_DESKTOP_ROOT") ||
    Path.join(System.user_home!(), "Library/Application Support/Manasprites")

if config_env() == :test do
  config :manasprites_desktop,
    root: Path.join(System.tmp_dir!(), "manasprites-desktop-tests-#{System.pid()}")
else
  config :manasprites_desktop, root: root
end

config :manasprites_desktop, ManaspritesDesktopWeb.Endpoint,
  server: config_env() != :test,
  http: [
    ip: {127, 0, 0, 1},
    port: String.to_integer(System.get_env("MANASPRITES_DESKTOP_PORT", "0"))
  ],
  url: [host: "127.0.0.1"],
  check_origin: :conn,
  secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64))

config :manasprites_desktop, headless: System.get_env("MANASPRITES_HEADLESS") == "true"

if port = System.get_env("MANASPRITES_API_PORT") do
  config :manasprites_desktop, fountain_port: String.to_integer(port)
end
