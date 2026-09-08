defmodule Managoat.Sprite.RuntimeEnvironmentTest do
  use Managoat.Sprite.TestCase
  alias Managoat.Sprite.{Execution, Runtime}

  test "Codex child routes approvals to the service despite a persisted adapter override", %{
    root: root
  } do
    config = Config.get()
    Application.put_env(:managoat_sprite, :config, Map.put(config, "runtime", "codex"))

    Config.private_write!(
      Path.join(root, "config/credentials.json"),
      Jason.encode!(%{"INITIAL_AGENT_MODE" => "agent-full-access"})
    )

    # Exercise the real subprocess boundary; checking the environment map alone
    # would not prove that erlexec delivers it to the adapter process.
    {:ok, child} =
      Execution.start("/bin/sh", ["-c", "printf '%s' \"$INITIAL_AGENT_MODE\""],
        env: Runtime.env()
      )

    assert_receive {:stdout, %{ref: ^child}, "read-only"}, 2000
    assert_receive {:exit, %{ref: ^child}, 0}, 2000

    Application.put_env(:managoat_sprite, :config, config)
  end
end
