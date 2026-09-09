defmodule ManaspritesDesktop.Recovery do
  use GenServer
  import Ecto.Query
  alias ManaspritesDesktop.{Agent, Job, Repo, Connection}
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    Repo.update_all(from(j in Job, where: j.state == "running" and j.kind == "workspace"),
      set: [
        state: "failed",
        error: "The app closed during inspection. Refresh to read the workspace again."
      ]
    )

    Repo.update_all(from(j in Job, where: j.state == "running" and j.kind != "workspace"),
      set: [
        state: "unknown",
        error:
          "The app closed before this operation was acknowledged. Refresh and review remote work."
      ]
    )

    Repo.update_all(Agent, set: [status: "disconnected"])
    {:ok, %{}, {:continue, :queued}}
  end

  @impl true
  def handle_continue(:queued, state) do
    Repo.all(from(j in Job, where: j.state == "queued", order_by: j.inserted_at))
    |> Enum.each(&Connection.enqueue/1)

    {:noreply, state}
  end
end
