defmodule ManaspritesDesktop.Provisioner do
  @moduledoc "Reconciles an owned Sprite before each resumable setup attempt."
  alias ManaspritesDesktop.{
    Platform,
    PlatformClient,
    Vault,
    RemoteExec,
    ServiceClient,
    Repo,
    Agent,
    Job,
    Fleet,
    Connection
  }

  def run(job) do
    with {:ok, raw} <- Vault.get("platform:" <> job.id),
         {:ok, secrets} <- Jason.decode(raw) do
      case job.kind do
        "discover" ->
          with {:ok, entries} <- PlatformClient.list(secrets["sprites"]) do
            # Catalogue records are metadata, never an arbitrary platform response.
            rows =
              Enum.map(entries, fn entry ->
                entry
                |> Map.take(~w(name organization org_slug status updated_at))
                |> Map.put(
                  "organization",
                  entry["organization"] || entry["org_slug"] || job.organization
                )
              end)

            {:ok, %{"sprites" => rows}}
          end

        "create" ->
          create(job, secrets)
      end
    end
  rescue
    _ -> {:error, :platform_unreachable}
  end

  defp create(job, secrets) do
    token = secrets["sprites"]

    with {:ok, info} <- ensure_sprite(job, token),
         :ok <- identity(job, info),
         :ok <- setup(job, secrets),
         {:ok, installed_sprite} <- PlatformClient.info(token, job.sprite_name),
         :ok <- identity(Platform.get(job.id), installed_sprite),
         {:ok, _} <-
           PlatformClient.request(token, :put, "/v1/sprites/" <> job.sprite_name, %{
             "url_settings" => %{"auth" => job.config["url_auth"]}
           }),
         {:ok, current} <- PlatformClient.info(token, job.sprite_name),
         :ok <- identity(Platform.get(job.id), current),
         :ok <- verify(current, secrets, job.config),
         {:ok, aid} <- register(job, current, secrets["client_key"]) do
      Platform.progress(job.id, stage: "ready", agent_id: aid)
      {:ok, %{"agent_id" => aid, "url" => current["url"], "inference_verified" => false}}
    end
  end

  defp ensure_sprite(job, token) do
    case PlatformClient.info(token, job.sprite_name) do
      {:ok, info} ->
        {:ok, info}

      {:error, {:platform_http, 404}} when not is_nil(job.sprite_id) ->
        {:error, :sprite_missing}

      {:error, {:platform_http, 404}} ->
        Platform.progress(job.id, stage: "creating")
        # A lost POST response is reconciled by name + operation label on the next
        # explicit retry. An existing unowned name is never adopted or deleted.
        with {:ok, _} <-
               PlatformClient.request(token, :post, "/v1/sprites", %{
                 "name" => job.sprite_name,
                 "labels" => ["managoat:" <> job.id],
                 "url_settings" => %{"auth" => "sprite"}
               }),
             do: PlatformClient.info(token, job.sprite_name)

      error ->
        error
    end
  end

  defp identity(job, info) do
    cond do
      not is_map(info) ->
        {:error, :platform_response_invalid}

      info["organization"] != job.organization ->
        {:error, :wrong_organization}

      info["name"] != job.sprite_name or not is_binary(info["id"]) ->
        {:error, :sprite_conflict}

      job.sprite_id && job.sprite_id != info["id"] ->
        {:error, :sprite_conflict}

      ("managoat:" <> job.id) not in (info["labels"] || []) ->
        {:error, :sprite_conflict}

      true ->
        Platform.progress(job.id, sprite_id: info["id"])
        :ok
    end
  end

  defp setup(job, secrets) do
    installed = job.stage in ~w(installed ready)
    Platform.progress(job.id, stage: if(installed, do: "installed", else: "installing"))

    credential =
      if job.config["agent"]["runtime"] == "codex",
        do: "OPENAI_API_KEY",
        else: "ANTHROPIC_API_KEY"

    payload =
      if installed do
        %{
          "action" => "status",
          "client_key_hash" =>
            Base.encode16(:crypto.hash(:sha256, secrets["client_key"]), case: :lower)
        }
      else
        %{
          "action" => "setup",
          "client_key" => secrets["client_key"],
          "env" => %{credential => secrets["inference"]},
          "git_auth" =>
            if(secrets["github"],
              do: %{"username" => "x-access-token", "token" => secrets["github"]}
            ),
          "retry_bootstrap" => false
        }
      end

    payload = Map.merge(payload, %{"config" => job.config, "operation_id" => job.id})

    case RemoteExec.setup(secrets["sprites"], job.sprite_name, payload) do
      {:ok, %{"ok" => true, "ready" => true}} ->
        Platform.progress(job.id, stage: "installed")
        :ok

      {:ok, %{"error" => code}} when is_binary(code) ->
        if Regex.match?(~r/\A[a-z_]{1,80}\z/, code),
          do: {:error, {:remote_setup, code}},
          else: {:error, :remote_unavailable}

      _ ->
        {:error, :remote_unavailable}
    end
  end

  defp verify(info, secrets, config) do
    url = info["url"]
    key = secrets["client_key"]
    runtime = config["agent"]["runtime"]
    auth = config["url_auth"]

    request = fn bearer, path ->
      if auth == "sprite" do
        ManaspritesDesktop.PrivateProxy.with_url(
          secrets["sprites"],
          info["name"],
          config["port"],
          fn local ->
            ServiceClient.request_with_key(local, bearer, :get, path)
          end
        )
      else
        ServiceClient.request_with_key(url, bearer, :get, path)
      end
    end

    with true <- ServiceClient.valid_origin?(url),
         ^auth <- get_in(info, ["url_settings", "auth"]),
         {:error, {:http, 401}} <- request.("", "/api/agents"),
         {:ok, %{"ready" => true, "runtime_available" => true}} <-
           request.(key, "/readyz"),
         {:ok, %{"contract" => "fountain-conversations-v1"}} <-
           request.(key, "/api/capabilities"),
         {:ok, %{"data" => [%{"id" => "default", "runtime" => ^runtime}]}} <-
           request.(key, "/api/agents") do
      :ok
    else
      _ -> {:error, :verification_failed}
    end
  end

  defp register(job, info, key) do
    # Use the operation UUID for the local agent too. Retrying after a commit
    # cannot create a second local connection or replace another connection.
    with {:ok, sealed} <- Vault.seal("agent:" <> job.id, key),
         {:ok, result} <-
           Repo.transaction(fn ->
             case Fleet.get(job.id) do
               nil ->
                 agent = %Agent{
                   id: job.id,
                   name: job.config["agent"]["name"],
                   organization: job.organization,
                   runtime: job.config["agent"]["runtime"],
                   url:
                     if(job.config["url_auth"] == "sprite",
                       do: "sprite://#{job.organization}/#{job.sprite_name}",
                       else: info["url"]
                     ),
                   workspace: job.config["workspace"],
                   sprite_name: job.sprite_name,
                   sprite_id: info["id"],
                   transport:
                     if(job.config["url_auth"] == "sprite", do: "private", else: "direct"),
                   port: job.config["port"]
                 }

                 Repo.insert!(agent)

                 Repo.insert_all(
                   ManaspritesDesktop.Credential,
                   [%{name: "agent:" <> job.id, ciphertext: sealed}],
                   log: false
                 )

                 Repo.insert!(%Job{agent_id: job.id, kind: "connect"})

               _ ->
                 nil
             end
           end) do
      if result, do: Connection.enqueue(result)
      Fleet.notify()
      {:ok, job.id}
    end
  end
end
