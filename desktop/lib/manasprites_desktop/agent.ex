defmodule ManaspritesDesktop.Agent do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "agents" do
    field(:name, :string)
    field(:organization, :string)
    field(:runtime, :string, default: "unverified")
    field(:url, :string)
    field(:workspace, :string)
    field(:sprite_name, :string)
    field(:sprite_id, :string)
    field(:transport, :string, default: "direct")
    field(:port, :integer, default: 8080)
    field(:status, :string, default: "connecting")
    field(:snapshot, :map, default: %{}, redact: true)
    field(:error, :string)
    field(:checked_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(agent, attrs) do
    changeset =
      agent
      |> cast(attrs, [:name, :organization, :url, :transport, :sprite_name, :port])
      |> validate_required([:name, :url])
      |> validate_inclusion(:transport, ~w(direct private))
      |> validate_number(:port, greater_than: 0, less_than: 65_536)
      |> validate_length(:name, min: 1, max: 100)
      |> unique_constraint(:url)

    if get_field(changeset, :transport) == "private" do
      changeset
      |> validate_required([:organization, :sprite_name])
      |> validate_format(:organization, ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/)
      |> validate_format(:sprite_name, ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/)
    else
      validate_change(changeset, :url, fn :url, value ->
        if ManaspritesDesktop.ServiceClient.valid_origin?(value),
          do: [],
          else: [url: "use an HTTPS origin or an HTTP loopback tunnel"]
      end)
    end
  end
end
