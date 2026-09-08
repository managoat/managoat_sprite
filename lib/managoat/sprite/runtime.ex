defmodule Managoat.Sprite.Runtime do
  @moduledoc "Managoat runtime provisioning in an installation-owned home."
  alias Managoat.Sprite.{Config, Execution}
  alias Managoat.Runtimes
  def home, do: Path.join(Config.root(), "runtime/home")
  def prefix, do: Path.join(Config.root(), "runtime/npm")

  def env do
    credentials =
      case File.read(Path.join(Config.root(), "config/credentials.json")) do
        {:ok, bytes} -> Jason.decode!(bytes)
        _ -> %{}
      end

    system_path =
      System.get_env("MANAGOAT_SYSTEM_PATH") || System.get_env("PATH") ||
        "/usr/local/bin:/usr/bin:/bin"

    node_bin =
      case File.read(Path.join(Config.root(), "runtime/node-bin")) do
        {:ok, path} -> String.trim(path) <> ":"
        _ -> ""
      end

    base = %{
      "HOME" => home(),
      "PATH" =>
        Path.join(home(), ".local/bin") <>
          ":" <> Path.join(prefix(), "bin") <> ":" <> node_bin <> system_path,
      "npm_config_prefix" => prefix(),
      "LANG" => "C.UTF-8",
      "CODEX_HOME" => Path.join(home(), ".codex"),
      "CLAUDE_CONFIG_DIR" => Path.join(home(), ".claude")
    }

    environment = Map.merge(base, credentials)

    # codex-acp 1.10 defaults to an automatic reviewer. Route escalation
    # requests to the ACP peer instead, so the service's effective ask/allow/
    # deny policy controls their resolution, including narrowed conversations.
    # The adapter calls this mode "read-only", but it permits workspace writes.
    environment =
      if Config.get()["runtime"] == "codex",
        do: Map.put(environment, "INITIAL_AGENT_MODE", "read-only"),
        else: environment

    Map.to_list(environment)
  end

  def resolve(cmd) do
    if Path.type(cmd) == :absolute do
      cmd
    else
      paths = env() |> Map.new() |> Map.fetch!("PATH") |> String.split(":")

      Enum.find_value(paths, cmd, fn path ->
        candidate = Path.join(path, cmd)
        if File.regular?(candidate), do: candidate
      end)
    end
  end

  def install do
    c = Config.get()
    File.mkdir_p!(home())
    File.mkdir_p!(c["workspace"])
    runtime = c["runtime"]
    {:ok, mod} = Runtimes.for_runtime(runtime)
    h = Managoat.Sprite.Sandbox.Local.build_handle("installation")
    agent = %{name: c["name"], model: c["model"], system: instructions(), mcp_servers: %{}}

    with :ok <- pin_node_path(),
         :ok <- install_cli(h, runtime),
         :ok <- Runtimes.ACP.install(h, runtime, env()),
         :ok <- Runtimes.Instructions.write(h, runtime, agent),
         :ok <- Runtimes.write_config(mod, h, agent),
         :ok <- Runtimes.prepare_sandbox(mod, h, agent, env()) do
      :ok
    end
  end

  defp pin_node_path do
    case System.cmd("node", ["-p", "require('path').dirname(process.execPath)"],
           stderr_to_stdout: true
         ) do
      {path, 0} ->
        path = String.trim(path)

        if Path.type(path) == :absolute and File.regular?(Path.join(path, "npm")) do
          Config.private_write!(Path.join(Config.root(), "runtime/node-bin"), path <> "\n")
          :ok
        else
          {:error, :node_toolchain_unavailable}
        end

      _ ->
        {:error, :node_toolchain_unavailable}
    end
  end

  defp install_cli(h, runtime) do
    package =
      %{"codex" => "@openai/codex@0.153.4", "claude" => "@anthropic-ai/claude-code@2.1.263"}[
        runtime
      ]

    case Managoat.Sandbox.exec(h, "npm", ["install", "-g", "--no-progress", package],
           env: env(),
           timeout: 180_000
         ) do
      {:ok, _, 0} -> :ok
      _ -> {:error, :cli_install_failed}
    end
  end

  def probe do
    with {:ok, pid} <- start(self()) do
      try do
        params = Managoat.Runtimes.ACP.initialize_params()

        :ok =
          write(
            pid,
            Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "initialize", params: params}) <> "\n"
          )

        probe_reply(pid, "", System.monotonic_time(:millisecond) + 30_000)
      after
        stop(pid)
      end
    end
  end

  defp probe_reply(pid, buffer, deadline) do
    receive do
      {:stdout, %{ref: ^pid}, bytes} ->
        parts = String.split(buffer <> bytes, "\n")
        frames = Enum.drop(parts, -1)

        if Enum.any?(frames, fn frame ->
             case Jason.decode(frame) do
               {:ok, %{"id" => 1, "result" => %{"protocolVersion" => 1}}} -> true
               _ -> false
             end
           end), do: :ok, else: probe_reply(pid, List.last(parts), deadline)

      {:stderr, %{ref: ^pid}, _} ->
        probe_reply(pid, buffer, deadline)

      {kind, %{ref: ^pid}, _} when kind in [:exit, :error] ->
        {:error, :agent_exited}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> {:error, :initialization_timeout}
    end
  end

  def reconcile do
    Enum.reduce_while(:exec.which_children(), :ok, fn {pid, _}, _ ->
      ref = Process.monitor(pid)
      :exec.stop(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> {:cont, :ok}
      after
        10_000 ->
          Process.demonitor(ref, [:flush])
          {:halt, {:error, :cleanup_unavailable}}
      end
    end)
  end

  def instructions, do: Config.instructions()

  def start(owner) do
    c = Config.get()
    {cmd, args} = Runtimes.ACP.command(c["runtime"])
    handle = Managoat.Sprite.Sandbox.Local.build_handle("launch")
    agent = %{name: c["name"], model: c["model"], system: instructions(), mcp_servers: %{}}

    with :ok <- Runtimes.Instructions.write(handle, c["runtime"], agent) do
      Execution.start(resolve(cmd), args, owner: owner, env: env(), dir: c["workspace"])
    end
  end

  def write(pid, data), do: Execution.write(pid, data)
  def connect(_, _), do: :ok
  def stop(pid), do: Execution.stop(pid)

  def ready? do
    {cmd, _} = Runtimes.ACP.command(Config.get()["runtime"])

    case File.stat(resolve(cmd)) do
      {:ok, %{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  def initialization_record do
    {cmd, _} = Runtimes.ACP.command(Config.get()["runtime"])
    path = resolve(cmd)
    stat = File.stat!(path, time: :posix)

    %{
      "runtime" => Config.get()["runtime"],
      "executable" => path,
      "size" => stat.size,
      "mtime" => stat.mtime
    }
  end

  def initialization_status do
    with {:ok, bytes} <- File.read(Path.join(Config.root(), "state/runtime-initialized.json")),
         {:ok, record} <- Jason.decode(bytes),
         true <- ready?() and record == initialization_record() do
      "verified_at_install"
    else
      _ -> "unverified"
    end
  end
end
