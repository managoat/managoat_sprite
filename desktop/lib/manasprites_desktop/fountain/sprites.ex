defmodule ManaspritesDesktop.Fountain.Sprites do
  @moduledoc "Owns only API-created Sprites; credentials remain on the host and in the chosen Sprite."
  alias ManaspritesDesktop.{PlatformClient, PrivateProxy, RemoteExec, ServiceClient, Vault}
  alias ManaspritesDesktop.Fountain.{Accounts, Store}
  @external_resource Path.expand("../../../priv/remote/workspace.py", __DIR__)
  @inspector File.read!(@external_resource)

  def provision(owner, c) do
    with {:ok, token} <- Accounts.credential(owner, "sprites"),
         {:ok, inference} <-
           Accounts.credential(
             owner,
             if(c["runtime"] == "codex", do: "openai", else: "anthropic")
           ),
         {:ok, info} <- ensure_sprite(owner, c, token),
         :ok <- identity(c, info),
         {:ok, key} <- service_key(c),
         {:ok, config, env} <- config(c, token, inference),
         {:ok, %{"ok" => true, "ready" => true}} <-
           RemoteExec.setup(token, c["sandbox"]["sprite_name"], %{
             "action" => "setup",
             "config" => config,
             "operation_id" => c["id"],
             "client_key" => key,
             "env" => env,
             "git_auth" => nil,
             "retry_bootstrap" => false
           }),
         {:ok, %{"ready" => true}} <- request(owner, c, :get, "/readyz") do
      {:ok, %{"_sprite_id" => info["id"]}}
    else
      _ -> {:error, "provision_failed"}
    end
  end

  defp ensure_sprite(owner, c, token) do
    name = c["sandbox"]["sprite_name"]

    case PlatformClient.info(token, name) do
      {:ok, info} ->
        remember(owner, c, info)

      {:error, {:platform_http, 404}} ->
        if c["_create_intent"] do
          {:error, :creation_outcome_unknown}
        else
          {:ok, _} =
            Store.transaction(fn ->
              Store.patch(owner, "conversation", c["id"], %{"_create_intent" => true})
            end)

          case PlatformClient.request(token, :post, "/v1/sprites", %{
                 "name" => name,
                 "labels" => [label(c)],
                 "url_settings" => %{"auth" => "sprite"}
               }) do
            {:ok, _} ->
              with {:ok, info} <- PlatformClient.info(token, name), do: remember(owner, c, info)

            error ->
              error
          end
        end

      error ->
        error
    end
  end

  defp remember(owner, c, info) do
    with :ok <- identity(c, info) do
      {:ok, _} =
        Store.transaction(fn ->
          Store.patch(owner, "conversation", c["id"], %{"_sprite_id" => info["id"]})
        end)

      {:ok, info}
    end
  end

  defp label(c), do: "manasprites-api:" <> c["id"]

  defp identity(c, info) do
    if info["name"] == c["sandbox"]["sprite_name"] and is_binary(info["id"]) and
         (is_nil(c["_sprite_id"]) or c["_sprite_id"] == info["id"]) and
         label(c) in (info["labels"] || []), do: :ok, else: {:error, :sprite_identity_changed}
  end

  defp service_key(c) do
    name = "fountain-service:" <> c["id"]

    case Vault.get(name) do
      {:ok, key} ->
        {:ok, key}

      {:error, :credential_missing} ->
        key = "mgt_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        with :ok <- Vault.put(name, key), do: {:ok, key}

      error ->
        error
    end
  end

  defp env_vars(%{"_env" => encoded, "id" => id}) do
    with {:ok, bytes} <- Base.decode64(encoded),
         {:ok, value} <- Vault.unseal("fountain-env:" <> id, bytes),
         do: Jason.decode!(value)
  end

  defp env_vars(_), do: %{}

  defp config(c, token, inference) do
    environment = c["_environment"]
    env = Map.merge(env_vars(environment), env_vars(c["_vault"]))
    runtime = c["runtime"]
    credential = if runtime == "codex", do: "OPENAI_API_KEY", else: "ANTHROPIC_API_KEY"
    agent = c["_agent"]

    {:ok,
     %{
       "name" => c["sandbox"]["sprite_name"],
       "org" => token |> String.split("/", parts: 3) |> hd(),
       "url_auth" => "sprite",
       "release" => "0.1.2",
       "workspace" => "/home/sprite/project",
       "port" => 8080,
       "repository" =>
         case List.first(environment["repositories"] || []) do
           nil -> nil
           repo -> Map.put_new(repo, "ref", "HEAD")
         end,
       "env" => Map.keys(env),
       "bootstrap" =>
         if(environment["setup_script"] in [nil, ""], do: [], else: [environment["setup_script"]]),
       "bootstrap_timeout_seconds" => 120,
       "cors_origins" => [],
       "agent" => %{
         "runtime" => runtime,
         "name" => agent["name"],
         "model" => agent["model"],
         "instructions" => agent["system"],
         "permissions" => agent["permission_policy"]
       }
     }, Map.put(env, credential, inference)}
  end

  def request(owner, c, method, path, body \\ nil, key_id \\ nil) do
    with {:ok, token} <- Accounts.credential(owner, "sprites"),
         {:ok, info} <- PlatformClient.info(token, c["sandbox"]["sprite_name"]),
         :ok <- identity(c, info),
         {:ok, key} <- Vault.get("fountain-service:" <> c["id"]) do
      PrivateProxy.with_url(token, info["name"], 8080, fn url ->
        ServiceClient.request_with_key(url, key, method, path, body, key_id)
      end)
    end
  end

  def file(owner, c, path, max_bytes) do
    with {:ok, token} <- Accounts.credential(owner, "sprites"),
         {:ok, info} <- PlatformClient.info(token, c["sandbox"]["sprite_name"]),
         :ok <- identity(c, info),
         {:ok, key} <- Vault.get("fountain-service:" <> c["id"]),
         {:ok, %{"ok" => true, "content" => _} = result} <-
           RemoteExec.script(token, info["name"], @inspector, %{
             "action" => "api_file",
             "path" => path,
             "max_bytes" => max_bytes,
             "client_key_hash" => Base.encode16(:crypto.hash(:sha256, key), case: :lower)
           }) do
      {:ok, Map.take(result, ~w(path content encoding size truncated))}
    else
      _ -> {:error, :file_unavailable}
    end
  end

  def destroy(owner, c) do
    with {:ok, token} <- Accounts.credential(owner, "sprites") do
      case PlatformClient.info(token, c["sandbox"]["sprite_name"]) do
        {:error, {:platform_http, 404}} ->
          if c["_create_intent"] and is_nil(c["_sprite_id"]),
            do: {:error, :creation_outcome_unknown},
            else: :ok

        {:ok, info} ->
          with :ok <- identity(c, info),
               {:ok, _} <- PlatformClient.request(token, :delete, "/v1/sprites/" <> info["name"]),
               {:error, {:platform_http, 404}} <- PlatformClient.info(token, info["name"]),
               do: :ok

        error ->
          error
      end
    end
  end
end
