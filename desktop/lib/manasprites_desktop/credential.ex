defmodule ManaspritesDesktop.Credential do
  use Ecto.Schema
  @primary_key {:name, :string, autogenerate: false}
  schema "credentials" do
    field(:ciphertext, :binary, redact: true)
  end
end
