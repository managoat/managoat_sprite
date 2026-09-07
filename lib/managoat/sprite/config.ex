defmodule Managoat.Sprite.Config do
  @moduledoc "Validated installation configuration. Secrets are loaded only for child execution."
  def root,
    do: System.get_env("MANAGOAT_ROOT") || Path.join(System.user_home!(), ".local/share/managoat")

  def path, do: Path.join(root(), "config/config.json")

  def load! do
    path() |> File.read!() |> Jason.decode!() |> validate!()
  end

  def validate!(c) do
    allowed =
      ~w(runtime workspace model name permissions cors_origins port host permission_timeout_seconds turn_timeout_seconds max_request_bytes max_output_bytes disk_reserve_bytes task_socket task_required credential_env)

    unknown = Map.keys(c) -- allowed
    if unknown != [], do: raise(ArgumentError, "unknown config keys: #{Enum.join(unknown, ", ")}")

    unless c["runtime"] in ["claude", "codex"],
      do: raise(ArgumentError, "runtime must be claude or codex")

    unless is_binary(c["workspace"]) and Path.type(c["workspace"]) == :absolute,
      do: raise(ArgumentError, "workspace must be an absolute path")

    defaults = %{
      "model" => nil,
      "name" => "Workspace agent",
      "permissions" => %{"default" => "auto_allow"},
      "cors_origins" => [],
      "port" => 8080,
      "host" => "0.0.0.0",
      "permission_timeout_seconds" => 300,
      "turn_timeout_seconds" => 3600,
      "max_request_bytes" => 1_048_576,
      "max_output_bytes" => 104_857_600,
      "disk_reserve_bytes" => 268_435_456,
      "task_socket" => "/.sprite/api.sock",
      "task_required" => true
    }

    c = Map.merge(defaults, c)

    if c["model"] do
      provider = Managoat.Runtimes.Model.provider(c["model"])

      unless provider == Managoat.Runtimes.Model.provider_for_runtime(c["runtime"]),
        do: raise(ArgumentError, "model must name the runtime's provider, e.g. openai/model-id")
    end

    unless is_binary(c["host"]) and
             match?({:ok, _}, :inet.parse_address(String.to_charlist(c["host"]))),
           do: raise(ArgumentError, "host must be an IP address")

    unless is_binary(c["name"]) and byte_size(c["name"]) > 0,
      do: raise(ArgumentError, "name must be nonempty")

    for key <-
          ~w(port permission_timeout_seconds turn_timeout_seconds max_request_bytes max_output_bytes) do
      unless is_integer(c[key]) and c[key] > 0,
        do: raise(ArgumentError, "#{key} must be positive")
    end

    unless c["port"] < 65536, do: raise(ArgumentError, "invalid port")

    unless is_map(c["permissions"]) and
             Enum.all?(c["permissions"], fn {k, v} ->
               is_binary(k) and v in ~w(auto_allow ask auto_deny)
             end),
           do: raise(ArgumentError, "invalid permission policy")

    unless is_list(c["cors_origins"]) and
             Enum.all?(c["cors_origins"], &(is_binary(&1) and &1 != "*")),
           do: raise(ArgumentError, "cors_origins must be explicit origins")

    unless is_boolean(c["task_required"]), do: raise(ArgumentError, "invalid task_required")

    unless is_integer(c["disk_reserve_bytes"]) and c["disk_reserve_bytes"] >= 0,
      do: raise(ArgumentError, "invalid disk reserve")

    c
  end

  def get, do: Application.fetch_env!(:managoat_sprite, :config)

  def database_path! do
    state = Path.join(root(), "state")
    path = Path.join(state, "managoat.sqlite3")

    established =
      File.exists?(Path.join(state, "installed.json")) or
        File.exists?(Path.join(state, "database-created.json"))

    valid =
      case File.stat(path) do
        {:ok, %{type: :regular, size: size}} -> size > 0
        _ -> false
      end

    if established and not valid,
      do: raise("database_missing: restore a backup; refusing to create empty history")

    path
  end

  def instructions do
    case File.read(Path.join(root(), "config/instructions.md")) do
      {:ok, text} ->
        text

      {:error, :enoent} ->
        "You are the workspace agent. Work in the configured project directory."

      {:error, _} ->
        raise ArgumentError, "cannot read configured instructions"
    end
  end

  def launch_configuration do
    Map.take(get(), ~w(runtime workspace))
    |> Map.put(
      "instructions_sha256",
      :crypto.hash(:sha256, instructions()) |> Base.encode16(case: :lower)
    )
  end

  def private_write!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o700)
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, bytes, [:exclusive])
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
  end

  def id, do: Ecto.UUID.generate()
  def now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
