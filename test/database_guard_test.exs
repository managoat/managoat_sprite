defmodule Managoat.Sprite.DatabaseGuardTest do
  use ExUnit.Case, async: false
  alias Managoat.Sprite.{Config, Application}

  setup do
    previous = System.get_env("MANAGOAT_ROOT")
    root = Path.join(System.tmp_dir!(), "managoat-database-guard-" <> Ecto.UUID.generate())
    System.put_env("MANAGOAT_ROOT", root)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous,
        do: System.put_env("MANAGOAT_ROOT", previous),
        else: System.delete_env("MANAGOAT_ROOT")
    end)

    %{root: root}
  end

  test "fresh installation can create state but established missing history cannot", %{root: root} do
    Application.children(%{})
    path = Path.join(root, "state/managoat.sqlite3")
    refute File.exists?(path)
    Config.private_write!(Path.join(root, "state/database-created.json"), "{}")
    assert_raise RuntimeError, ~r/database_missing/, fn -> Application.children(%{}) end
    refute File.exists?(path)
    File.write!(path, "")
    assert_raise RuntimeError, ~r/database_missing/, fn -> Application.children(%{}) end
    assert File.stat!(path).size == 0
  end

  test "earlier installation marker also prevents empty replacement", %{root: root} do
    Config.private_write!(Path.join(root, "state/installed.json"), "{}")
    assert_raise RuntimeError, ~r/database_missing/, fn -> Config.database_path!() end
    refute File.exists?(Path.join(root, "state/managoat.sqlite3"))
  end
end
