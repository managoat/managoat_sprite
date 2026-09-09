defmodule ManaspritesDesktop.Repo.Migrations.PrivateConnections do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add(:transport, :text, null: false, default: "direct")
      add(:port, :integer, null: false, default: 8080)
    end
  end
end
