defmodule Managoat.Sprite.Repo.Migrations.Initialize do
  use Ecto.Migration

  def change do
    create table(:installation, primary_key: false) do
      add(:id, :integer, primary_key: true)
      add(:identity, :text, null: false)
    end

    create table(:conversations, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:status, :text, null: false)
      add(:record, :text, null: false)
    end

    create table(:turns, primary_key: false) do
      add(:id, :text, primary_key: true)

      add(:conversation_id, references(:conversations, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:number, :integer, null: false)
      add(:active, :boolean, null: false, default: true)
      add(:phase, :text, null: false)
      add(:record, :text, null: false)
    end

    create(unique_index(:turns, [:conversation_id, :number]))

    execute(
      "CREATE UNIQUE INDEX one_admitted_turn ON turns(active) WHERE active = 1",
      "DROP INDEX one_admitted_turn"
    )

    # SQLite AUTOINCREMENT deliberately prevents cursor reuse after deletion.
    execute(
      "CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE, turn_id TEXT, record TEXT NOT NULL)",
      "DROP TABLE events"
    )

    create(index(:events, [:conversation_id, :id]))

    create table(:permissions, primary_key: false) do
      add(:id, :text, primary_key: true)

      add(:conversation_id, references(:conversations, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:turn_id, :text, null: false)
      add(:record, :text, null: false)
    end

    create table(:idempotency, primary_key: false) do
      add(:key, :text, primary_key: true)
      add(:fingerprint, :text, null: false)
      add(:conversation_id, :text, null: false)
      add(:response, :text, null: false)
      add(:deleted, :boolean, null: false, default: false)
    end

    create table(:api_keys, primary_key: false) do
      add(:digest, :text, primary_key: true)
      add(:created_at, :text, null: false)
    end
  end
end

defmodule Managoat.Sprite.Repo.Migrations.AgentConfigurations do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:agent_id, :text, null: false)
      add(:record, :text, null: false)
    end
  end
end

defmodule Managoat.Sprite.Repo.Migrations.A2ATasks do
  use Ecto.Migration

  def change do
    create table(:a2a_tasks, primary_key: false) do
      add(:id, references(:turns, type: :text, on_delete: :delete_all), primary_key: true)
      add(:message_id, :text, null: false)
      add(:text, :text, null: false, default: "")
      add(:truncated, :boolean, null: false, default: false)
      add(:updated_at, :text, null: false)
      add(:event_id, :integer, null: false, default: 0)
    end

    create(index(:a2a_tasks, [:updated_at, :id]))
  end
end
