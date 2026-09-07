defmodule Managoat.Sprite.MixProject do
  use Mix.Project

  def project do
    [
      app: :managoat_sprite,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: [
        {:bandit, "~> 1.8"},
        {:plug, "~> 1.18"},
        {:jason, "~> 1.4"},
        {:ecto_sqlite3, "~> 0.22"},
        {:erlexec, "~> 2.3"},
        {:managoat_acp, "~> 0.2.3", override: true},
        {:managoat_runtimes, "~> 0.3.0"},
        {:managoat_sandbox, "~> 0.2.0"}
      ],
      aliases: [check: ["format --check-formatted", "compile --warnings-as-errors", "test"]],
      releases: [managoat: [include_erts: true]]
    ]
  end

  def cli, do: [preferred_envs: [check: :test]]

  def application do
    [
      mod: {Managoat.Sprite.Application, []},
      extra_applications: [:logger, :crypto, :ssl, :os_mon]
    ]
  end
end
