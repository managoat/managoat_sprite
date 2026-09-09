defmodule ManaspritesDesktop.Job do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "jobs" do
    field(:agent_id, :binary_id)
    field(:kind, :string)
    field(:state, :string, default: "queued")
    field(:payload, :map, default: %{}, redact: true)
    field(:result, :map, default: %{}, redact: true)
    field(:error, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
