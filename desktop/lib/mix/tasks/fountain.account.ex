defmodule Mix.Tasks.Fountain.Account do
  @shortdoc "Import an operator-verified Fountain API account; secrets come from named environment variables"
  use Mix.Task

  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          email: :string,
          verified_email: :boolean,
          key_env: :string,
          sprites_env: :string,
          openai_env: :string,
          anthropic_env: :string
        ]
      )

    if rest != [] or invalid != [], do: Mix.raise("Unknown account arguments")
    Application.put_env(:manasprites_desktop, :headless, true)
    Mix.Task.run("app.start")

    credentials =
      for name <- ~w(sprites openai anthropic),
          env = opts[String.to_existing_atom(name <> "_env")],
          into: %{},
          do: {name, System.fetch_env!(env)}

    account =
      ManaspritesDesktop.Fountain.Accounts.import(
        Keyword.fetch!(opts, :email),
        System.fetch_env!(Keyword.fetch!(opts, :key_env)),
        credentials,
        opts[:verified_email]
      )

    Mix.shell().info("Imported account #{account["id"]}; credential values omitted.")
  end
end
