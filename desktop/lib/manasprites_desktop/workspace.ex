defmodule ManaspritesDesktop.Workspace do
  @moduledoc "Authenticated, bounded reads of an agent's configured Sprite workspace."
  import Ecto.Query
  alias ManaspritesDesktop.{Agent, Job, Repo, Vault, PlatformClient, RemoteExec}
  @external_resource Path.expand("../../priv/remote/workspace.py", __DIR__)
  @source File.read!(@external_resource)

  def valid?(payload) do
    path = payload["path"] || ""

    payload["action"] in ~w(link list file status diff) and is_binary(path) and
      byte_size(path) <= 4096 and String.valid?(path) and not String.contains?(path, <<0>>) and
      (path == "" or
         (not String.starts_with?(path, "/") and
            Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", "..", ".git"])))) and
      (payload["action"] != "link" or
         (PlatformClient.name?(payload["sprite_name"]) and
            PlatformClient.name?(payload["organization"]))) and
      payload["staged"] in [nil, true, false]
  end

  def latest(aid, action, path, staged) do
    actions = if action == "list" and path == "", do: ["list", "link"], else: [action]

    Repo.one(
      from(j in Job,
        where:
          j.agent_id == ^aid and j.kind == "workspace" and j.state != "stale" and
            fragment("json_extract(?, '$.action')", j.payload) in ^actions and
            fragment("coalesce(json_extract(?, '$.path'), '')", j.payload) == ^path and
            fragment("coalesce(json_extract(?, '$.staged'), 0)", j.payload) ==
              ^if(staged, do: 1, else: 0),
        order_by: [desc: j.inserted_at],
        limit: 1
      )
    )
  end

  def job(aid, jid),
    do:
      Repo.one(
        from(j in Job, where: j.id == ^jid and j.agent_id == ^aid and j.kind == "workspace")
      )

  def run(agent, payload) do
    linking = payload["action"] == "link"
    name = if linking, do: payload["sprite_name"], else: agent.sprite_name
    org = if linking, do: payload["organization"], else: agent.organization

    with true <- PlatformClient.name?(name) and PlatformClient.name?(org),
         {:ok, token} <- Vault.get("sprites"),
         [^org, _, _] <- String.split(token, "/", parts: 3),
         {:ok, info} <- PlatformClient.info(token, name),
         true <- info["name"] == name and info["organization"] == org and is_binary(info["id"]),
         true <- linking or info["id"] == agent.sprite_id,
         {:ok, key} <- Vault.get("agent:" <> agent.id),
         request =
           payload
           |> Map.take(~w(action path staged))
           |> Map.put("client_key_hash", Base.encode16(:crypto.hash(:sha256, key), case: :lower)),
         {:ok, %{"ok" => true, "workspace" => workspace} = result} <-
           RemoteExec.script(token, name, @source, request),
         true <- is_binary(workspace) do
      if linking do
        # The remote helper checked this exact service key before revealing files.
        Repo.transaction(fn ->
          Repo.update_all(
            from(j in Job,
              where: j.agent_id == ^agent.id and j.kind == "workspace" and j.state == "completed"
            ),
            set: [
              state: "stale",
              result: %{},
              error: "The Sprite link changed. Refresh this workspace view."
            ]
          )

          Repo.update!(
            Ecto.Changeset.change(Repo.get!(Agent, agent.id),
              sprite_name: name,
              sprite_id: info["id"],
              organization: org,
              url:
                if(agent.transport == "private", do: "sprite://#{org}/#{name}", else: agent.url),
              workspace: workspace
            )
          )
        end)
      end

      {:ok, result}
    else
      {:ok, %{"ok" => false, "error" => error}} when is_binary(error) ->
        {:error, {:inspection, error}}

      {:error, error} ->
        {:error, error}

      _ ->
        {:error, :workspace_identity}
    end
  end

  def message({:inspection, "service_key_mismatch"}),
    do: "This Sprite is running a different agent service. Its files were not read."

  def message({:inspection, "invalid_path"}),
    do: "Choose a path inside the project workspace. Git internals are not browsable."

  def message({:inspection, "not_regular_file"}),
    do: "Only regular project files can be previewed."

  def message({:inspection, "git_timeout"}), do: "Git inspection timed out. Try a narrower view."

  def message({:inspection, _}),
    do: "This workspace entry is unavailable. Symlinks and special files are not followed."

  def message(:workspace_identity),
    do:
      "Link this agent to its Sprite and use a token for the same organization. A replaced Sprite must be linked again."

  def message(error), do: PlatformClient.message(error)
end
