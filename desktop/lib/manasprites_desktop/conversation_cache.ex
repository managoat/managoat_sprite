defmodule ManaspritesDesktop.ConversationCache do
  use Ecto.Schema
  @primary_key false
  schema "conversation_cache" do
    field(:agent_id, :binary_id, primary_key: true)
    field(:remote_id, :string, primary_key: true)
    field(:turns, :map, default: %{}, redact: true)
  end
end
