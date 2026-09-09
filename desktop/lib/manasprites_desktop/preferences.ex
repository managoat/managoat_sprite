defmodule ManaspritesDesktop.Preferences do
  import Ecto.Query
  alias ManaspritesDesktop.Repo

  def workspace_name do
    Repo.one(from(p in "preferences", where: p.key == "workspace_name", select: p.value)) ||
      "Personal workspace"
  end

  def rename_workspace(name) when is_binary(name) do
    name = String.trim(name)

    if byte_size(name) in 1..100 do
      Repo.insert_all("preferences", [%{key: "workspace_name", value: name}],
        on_conflict: {:replace, [:value]},
        conflict_target: :key
      )

      Phoenix.PubSub.broadcast(ManaspritesDesktop.PubSub, "fleet", :changed)
      :ok
    else
      {:error, :invalid_name}
    end
  end
end
