defmodule ManaspritesDesktop.WorkspaceTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest
  require Ecto.Query
  import Phoenix.LiveViewTest
  alias ManaspritesDesktop.{Bootstrap, Preferences, Repo}
  @endpoint ManaspritesDesktopWeb.Endpoint

  setup do
    root = Path.join(System.tmp_dir!(), "manasprites-workspace-#{Ecto.UUID.generate()}")
    Application.put_env(:manasprites_desktop, :root, root)

    start_supervised!(%{
      id: :desktop,
      start:
        {Supervisor, :start_link,
         [ManaspritesDesktop.Application.children(), [strategy: :rest_for_one]]},
      type: :supervisor
    })

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "unauthenticated and cross-origin local requests cannot access the workspace" do
    assert local_conn() |> get("/") |> response(401)
    assert build_conn() |> get("/") |> response(403)

    assert local_conn()
           |> put_req_header("origin", "https://example.test")
           |> get("/launch", %{token: Bootstrap.token()})
           |> response(403)

    assert local_conn() |> get("/launch", %{token: "wrong"}) |> response(401)
  end

  test "a real LiveView saves workspace state through Ecto and publishes to another window", %{
    root: root
  } do
    conn = local_conn() |> get("/launch", %{token: Bootstrap.token()})
    assert redirected_to(conn) == "/"
    {:ok, first, _} = conn |> recycle() |> live("/")
    {:ok, second, _} = conn |> recycle() |> live("/")
    assert has_element?(first, "#fleet-overview")
    first |> element("#settings-open") |> render_click()
    first |> form("#workspace-form", %{name: "Packaging test workspace"}) |> render_submit()
    assert Preferences.workspace_name() == "Packaging test workspace"
    assert has_element?(second, "#workspace-name", "Packaging test workspace")
    assert File.stat!(Path.join(root, "fleet.sqlite3")).mode |> Bitwise.band(0o777) == 0o600

    assert [%{key: "workspace_name", value: "Packaging test workspace"}] ==
             Repo.all(Ecto.Query.from(p in "preferences", select: %{key: p.key, value: p.value}))
  end

  defp local_conn do
    %{build_conn() | host: "127.0.0.1"}
  end
end
