defmodule ManaspritesDesktop.PlatformJob do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "platform_jobs" do
    field(:kind, :string)
    field(:state, :string, default: "queued")
    field(:stage, :string, default: "validated")
    field(:organization, :string)
    field(:sprite_name, :string)
    field(:sprite_id, :string)
    field(:agent_id, :binary_id)
    field(:config, :map, default: %{}, redact: true)
    field(:result, :map, default: %{}, redact: true)
    field(:error, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
