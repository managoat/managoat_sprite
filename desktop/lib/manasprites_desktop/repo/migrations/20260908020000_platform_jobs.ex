defmodule ManaspritesDesktop.Repo.Migrations.PlatformJobs do
  use Ecto.Migration

  def change do
    create table(:platform_jobs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:kind, :string, null: false)
      add(:state, :string, null: false, default: "queued")
      add(:stage, :string, null: false, default: "validated")
      add(:organization, :string)
      add(:sprite_name, :string)
      add(:sprite_id, :string)
      add(:agent_id, :binary_id)
      add(:config, :map, null: false, default: %{})
      add(:result, :map, null: false, default: %{})
      add(:error, :string)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:platform_jobs, [:organization, :sprite_name], where: "kind = 'create'"))

    alter table(:agents) do
      add(:sprite_name, :string)
      add(:sprite_id, :string)
    end
  end
end
