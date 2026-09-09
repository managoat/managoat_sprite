defmodule ManaspritesDesktop.MixProject do
  use Mix.Project

  def project do
    [
      app: :manasprites_desktop,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      deps: [
        {:phoenix, "~> 1.8.5"},
        {:phoenix_live_view, "~> 1.1.0"},
        {:phoenix_html, "~> 4.1"},
        {:bandit, "~> 1.8"},
        {:jason, "~> 1.4"},
        {:ecto_sqlite3, "~> 0.22"},
        {:req, "~> 0.5"},
        {:sprites, "~> 0.2.2"},
        {:gun, "~> 2.5"},
        {:elixirkit, "~> 0.1.0"},
        {:lazy_html, ">= 0.1.0", only: :test},
        {:managoat_sprite, path: "..", only: :test, runtime: false}
      ],
      aliases: [check: ["format --check-formatted", "compile --warnings-as-errors", "test"]],
      releases: [manasprites_desktop: [include_erts: true, cookie: "unused"]]
    ]
  end

  def cli, do: [preferred_envs: [check: :test]]

  def application do
    [mod: {ManaspritesDesktop.Application, []}, extra_applications: [:logger, :crypto, :ssl]]
  end
end
