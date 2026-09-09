defmodule ManaspritesDesktop.EventCache do
  use Ecto.Schema
  @primary_key false
  schema "event_cache" do
    field(:agent_id, :binary_id, primary_key: true)
    field(:conversation_id, :string, primary_key: true)
    field(:remote_id, :integer, primary_key: true)
    field(:record, :map, redact: true)
  end
end
