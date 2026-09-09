defmodule ManaspritesDesktop.ServiceFixture do
  alias Managoat.ACP.Testing.ScriptedAgent
  def start(_), do: ScriptedAgent.start_link(Application.fetch_env!(:managoat_sprite, :script))
  def write(pid, bytes), do: ScriptedAgent.writer(pid).(bytes)
  def connect(pid, peer), do: ScriptedAgent.connect(pid, peer)
  def stop(pid), do: if(Process.alive?(pid), do: GenServer.stop(pid), else: :ok)
  def ready?, do: true
  def reconcile, do: :ok
end

defmodule ManaspritesDesktop.HeldPermissionRuntime do
  @moduledoc false
  alias ManaspritesDesktop.ServiceFixture
  defdelegate start(opts), to: ServiceFixture
  defdelegate connect(pid, peer), to: ServiceFixture
  defdelegate stop(pid), to: ServiceFixture
  defdelegate ready?(), to: ServiceFixture
  defdelegate reconcile(), to: ServiceFixture

  def write(pid, bytes) do
    case Jason.decode(IO.iodata_to_binary(bytes)) do
      {:ok, %{"result" => %{"outcome" => _}}} ->
        owner = Application.fetch_env!(:managoat_sprite, :script) |> Keyword.fetch!(:observer)
        send(owner, {:permission_write_held, self()})

        receive do
          :release_permission -> :ok
        after
          2000 -> :ok
        end

      _ ->
        :ok
    end

    ServiceFixture.write(pid, bytes)
  end
end
