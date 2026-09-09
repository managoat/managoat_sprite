defmodule ManaspritesDesktop.Repo.Migrations.FountainAPI do
  use Ecto.Migration

  def change do
    create table(:fountain_objects, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:owner, :text, null: false)
      add(:kind, :text, null: false)
      add(:record, :text, null: false)
    end

    create(index(:fountain_objects, [:owner, :kind]))

    create table(:fountain_events) do
      add(:owner, :text, null: false)
      add(:conversation_id, :text, null: false)
      add(:source_id, :text, null: false)
      add(:record, :text, null: false)
    end

    create(unique_index(:fountain_events, [:conversation_id, :source_id]))
    create(index(:fountain_events, [:owner, :conversation_id, :id]))
  end
end
