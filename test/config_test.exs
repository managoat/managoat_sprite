defmodule Managoat.Sprite.ConfigTest do
  use ExUnit.Case, async: true
  alias Managoat.Sprite.Config

  test "configuration rejects unknown fields and invalid authority controls" do
    base = %{"runtime" => "codex", "workspace" => "/project"}
    assert Config.validate!(base)["port"] == 8080

    for bad <- [
          %{"unknown" => true},
          %{"port" => 0},
          %{"permissions" => %{"default" => "perhaps"}},
          %{"cors_origins" => ["*"]},
          %{"workspace" => "relative"}
        ] do
      assert_raise ArgumentError, fn -> Config.validate!(Map.merge(base, bad)) end
    end
  end
end
