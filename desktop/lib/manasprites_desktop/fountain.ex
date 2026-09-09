defmodule ManaspritesDesktop.Fountain do
  @moduledoc "Fountain-compatible host API for account-owned ephemeral Sprites."
  alias ManaspritesDesktop.Fountain.{Store, Worker}

  def backend,
    do:
      Application.get_env(
        :manasprites_desktop,
        :fountain_backend,
        ManaspritesDesktop.Fountain.Sprites
      )

  def create(owner, kind, attrs) when kind in ~w(agent environment vault) do
    Store.transaction(fn ->
      quota!(owner, kind)
      record = validate!(owner, kind, attrs, %{"id" => Store.id(), "inserted_at" => Store.now()})
      Store.put(owner, kind, record) |> Store.public()
    end)
  end

  def update(owner, kind, id, attrs) do
    Store.transaction(fn ->
      current = Store.fetch!(owner, kind, id)
      record = validate!(owner, kind, attrs, current)
      Store.put(owner, kind, record) |> Store.public()
    end)
  end

  def remove(owner, kind, id) do
    Store.transaction(fn ->
      current = Store.fetch!(owner, kind, id)

      if kind == "conversation" and current["_phase"] != "terminated",
        do: Store.abort("conversation_busy", 409)

      if kind in ~w(agent environment vault) do
        for c <- Store.list(owner, "conversation"),
            c[kind <> "_id"] == id,
            do: Store.abort("resource_in_use", 409)

        for a <- Store.list(owner, "agent"),
            kind != "agent" and a[kind <> "_id"] == id,
            do: Store.abort("resource_in_use", 409)
      end

      Store.delete(owner, kind, id)

      if kind == "conversation",
        do:
          Store.query("DELETE FROM fountain_events WHERE owner=? AND conversation_id=?", [
            owner,
            id
          ])

      :ok
    end)
  end

  defp validate!(owner, kind, attrs, current) do
    common = ~w(name metadata)

    extra =
      case kind do
        "agent" ->
          ~w(runtime model system description environment_id vault_id sandbox_provider sandbox_mode permission_policy)

        "environment" ->
          ~w(env_vars repositories setup_script)

        "vault" ->
          ~w(description env_vars)
      end

    fields!(attrs, common ++ extra)
    value = Map.merge(current, attrs)
    text!(value["name"], "name", 200)
    if not is_map(value["metadata"] || %{}), do: invalid!("metadata")

    for field <- ~w(system description setup_script),
        Map.has_key?(value, field),
        do: text!(value[field], field, 65_536, true)

    value = Map.put(value, "updated_at", Store.now()) |> Map.put_new("metadata", %{})

    value =
      if kind == "agent" do
        value =
          value
          |> Map.put_new("runtime", "claude")
          |> Map.put_new("sandbox_provider", "sprites")
          |> Map.put_new("sandbox_mode", "ephemeral")

        if value["runtime"] not in ~w(codex claude), do: invalid!("runtime")
        text!(value["model"], "model", 200)
        prefix = if value["runtime"] == "codex", do: "openai/", else: "anthropic/"

        if not String.starts_with?(value["model"], prefix) or value["model"] == prefix,
          do: invalid!("model")

        if value["sandbox_provider"] != "sprites", do: invalid!("sandbox_provider")
        if value["sandbox_mode"] != "ephemeral", do: invalid!("sandbox_mode")
        policy = value["permission_policy"] || %{"default" => "auto_allow"}

        if not is_map(policy) or
             not Enum.all?(policy, fn {_, v} -> v in ~w(ask auto_allow auto_deny) end),
           do: invalid!("permission_policy")

        for parent <- ~w(environment vault),
            value[parent <> "_id"],
            do: Store.fetch!(owner, parent, value[parent <> "_id"])

        Map.put(value, "permission_policy", policy)
      else
        value
      end

    if kind == "environment" do
      repos = value["repositories"] || []
      if not is_list(repos) or length(repos) > 1, do: invalid!("repositories")

      Enum.each(repos, fn repo ->
        if not is_map(repo) or Map.keys(repo) -- ~w(url ref) != [] or not is_binary(repo["url"]),
          do: invalid!("repositories")

        uri = URI.parse(repo["url"])

        if (uri.scheme != "https" or not is_binary(uri.host) or uri.userinfo) || uri.query ||
             uri.fragment,
           do: invalid!("repositories")

        text!(repo["ref"] || "HEAD", "ref", 256)
        if String.starts_with?(repo["ref"] || "HEAD", "-"), do: invalid!("ref")
      end)
    end

    if Map.has_key?(attrs, "env_vars") do
      vars = attrs["env_vars"]

      if not is_map(vars) or
           not Enum.all?(vars, fn {k, v} ->
             Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, k) and is_binary(v)
           end),
         do: invalid!("env_vars")

      # Seal before persistence; these values never enter an unencrypted resource row.
      sealed =
        case ManaspritesDesktop.Vault.seal("fountain-env:" <> value["id"], Jason.encode!(vars)) do
          {:ok, sealed} -> sealed
          _ -> invalid!("env_vars")
        end

      value
      |> Map.delete("env_vars")
      |> Map.put("_env", Base.encode64(sealed))
      |> Map.put("secret_count", map_size(vars))
    else
      value
    end
  end

  def create_conversation(owner, attrs) do
    result =
      Store.transaction(fn ->
        fields!(
          attrs,
          ~w(agent_id environment_id vault_id title channel_id sandbox_mode prompt permission_policy)
        )

        agent = Store.fetch!(owner, "agent", attrs["agent_id"] || "")
        if attrs["sandbox_mode"] not in [nil, "ephemeral"], do: invalid!("sandbox_mode")
        env_id = attrs["environment_id"] || agent["environment_id"]
        vault_id = attrs["vault_id"] || agent["vault_id"]
        env = if env_id, do: Store.fetch!(owner, "environment", env_id), else: %{}
        vault = if vault_id, do: Store.fetch!(owner, "vault", vault_id), else: %{}
        for field <- ~w(title channel_id), attrs[field], do: text!(attrs[field], field, 300)
        if attrs["prompt"], do: text!(attrs["prompt"], "prompt", 1_000_000)
        policy = attrs["permission_policy"] || agent["permission_policy"]

        if policy != agent["permission_policy"],
          do: Store.abort("unsupported_permission_override")

        id = Store.id()

        sandbox = %{
          "id" => Store.id(),
          "agent_id" => agent["id"],
          "environment_id" => env_id,
          "vault_id" => vault_id,
          "sprite_name" => "msp-api-" <> id,
          "provider" => "sprites",
          "mode" => "ephemeral",
          "status" => "pending"
        }

        record = %{
          "id" => id,
          "agent_id" => agent["id"],
          "environment_id" => env_id,
          "vault_id" => vault_id,
          "sandbox_id" => sandbox["id"],
          "sandbox" => sandbox,
          "title" => attrs["title"],
          "channel_id" => attrs["channel_id"],
          "runtime" => agent["runtime"],
          "status" => "pending",
          "turn_count" => 0,
          "usage_total" => %{"input" => 0, "output" => 0},
          "inserted_at" => Store.now(),
          "permission_policy" => policy,
          "_phase" => "provision",
          "_agent" => agent,
          "_environment" => env,
          "_vault" => vault,
          "_cursor" => 0,
          "_turns" => [],
          "_initial_prompt" => attrs["prompt"]
        }

        Store.put(owner, "conversation", record)
        Store.stage(owner, id, "provision", "started")
        record
      end)

    launch(result, owner)
  end

  def prompt(owner, id, attrs) do
    result =
      Store.transaction(fn ->
        fields!(attrs, ~w(prompt))
        text!(attrs["prompt"], "prompt", 1_000_000)
        c = Store.fetch!(owner, "conversation", id)
        if c["_phase"] == "terminated", do: Store.abort("conversation_terminated", 410)
        if c["_phase"] != "idle", do: Store.abort("conversation_busy", 409)

        Store.patch(owner, "conversation", id, %{
          "_phase" => "prompt",
          "_terminal_seen" => false,
          "status" => "running",
          "_operation" => %{"id" => Store.id(), "prompt" => attrs["prompt"]}
        })
      end)

    launch(result, owner)
  end

  def terminate(owner, id) do
    result =
      Store.transaction(fn ->
        c = Store.fetch!(owner, "conversation", id)

        if c["_phase"] == "terminated",
          do: c,
          else: Store.patch(owner, "conversation", id, %{"_action" => "terminate"})
      end)

    launch(result, owner)
  end

  defp launch({:ok, c}, owner) do
    Worker.wake(owner, c["id"])
    {:ok, Store.public(c)}
  end

  defp launch(error, _), do: error

  defp quota!(owner, kind) do
    if length(Store.list(owner, kind)) >= 1000, do: Store.abort("resource_limit", 429)
  end

  def fields!(attrs, allowed) do
    if not is_map(attrs) or Map.keys(attrs) -- allowed != [],
      do: Store.abort("unsupported_feature")
  end

  def text!(value, field, max, blank? \\ false) do
    if not is_binary(value) or byte_size(value) > max or (not blank? and String.trim(value) == ""),
      do: invalid!(field)
  end

  def invalid!(field),
    do:
      ManaspritesDesktop.Repo.rollback(
        {422, "validation_failed", %{field => ["is invalid or unsupported"]}}
      )
end
