defmodule ManaspritesDesktop.Repo.Migrations.LocalConnections do
  use Ecto.Migration

  def change do
    create table(:credentials, primary_key: false) do
      add(:name, :string, primary_key: true)
      add(:ciphertext, :binary, null: false)
    end

    alter table(:agents) do
      add(:workspace, :string)
      add(:snapshot, :map, default: %{}, null: false)
      add(:error, :string)
      add(:checked_at, :utc_datetime_usec)
    end

    create(unique_index(:agents, [:url]))

    create table(:jobs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false)
      add(:kind, :string, null: false)
      add(:state, :string, default: "queued", null: false)
      add(:payload, :map, default: %{}, null: false)
      add(:result, :map, default: %{}, null: false)
      add(:error, :string)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:jobs, [:agent_id, :inserted_at]))

    create(
      unique_index(:jobs, [:agent_id],
        name: :one_pending_prompt,
        where: "kind = 'prompt' AND state IN ('queued', 'running', 'unknown')"
      )
    )

    create table(:conversation_cache, primary_key: false) do
      add(:agent_id, references(:agents, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:remote_id, :string, primary_key: true)
      add(:turns, :map, default: %{}, null: false)
    end

    create table(:event_cache, primary_key: false) do
      add(:agent_id, references(:agents, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:conversation_id, :string, primary_key: true)
      add(:remote_id, :integer, primary_key: true)
      add(:record, :map, null: false)
    end
  end
end
