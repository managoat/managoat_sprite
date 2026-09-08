defmodule ManaspritesDesktop.Repo.Migrations.CreateFleet do
  use Ecto.Migration

  def change do
    create table(:preferences, primary_key: false) do
      add(:key, :string, primary_key: true)
      add(:value, :string, null: false)
    end

    create table(:agents, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:organization, :string)
      add(:runtime, :string, null: false)
      add(:url, :string)
      add(:status, :string, null: false, default: "disconnected")
      timestamps(type: :utc_datetime_usec)
    end
  end
end
