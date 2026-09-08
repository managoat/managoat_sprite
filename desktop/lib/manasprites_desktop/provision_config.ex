defmodule ManaspritesDesktop.ProvisionConfig do
  @moduledoc "Validated, non-secret initial agent configuration."
  alias ManaspritesDesktop.PlatformClient

  def build(attrs) do
    runtime = attrs["runtime"]
    repository = String.trim(attrs["repository"] || "")
    ref = String.trim(attrs["ref"] || "HEAD")
    name = String.trim(attrs["name"] || "")
    org = String.trim(attrs["organization"] || "")
    display = String.trim(attrs["display_name"] || name)
    display = if display == "", do: name, else: display
    instructions = attrs["instructions"] || ""
    model = String.trim(attrs["model"] || "")
    provider = if runtime == "codex", do: "openai/", else: "anthropic/"

    cond do
      not PlatformClient.name?(name) or not PlatformClient.name?(org) ->
        {:error, :invalid_config}

      runtime not in ~w(codex claude) or display == "" or byte_size(display) > 100 ->
        {:error, :invalid_config}

      attrs["url_auth"] not in ~w(public sprite) ->
        {:error, :invalid_config}

      attrs["permissions"] not in ~w(ask auto_allow auto_deny) ->
        {:error, :invalid_config}

      byte_size(instructions) > 65_536 or byte_size(model) > 200 ->
        {:error, :invalid_config}

      model != "" and (not String.starts_with?(model, provider) or model == provider) ->
        {:error, :invalid_config}

      repository != "" and not repository?(repository) ->
        {:error, :invalid_config}

      ref == "" or String.starts_with?(ref, "-") or byte_size(ref) > 256 ->
        {:error, :invalid_config}

      true ->
        {:ok,
         %{
           "name" => name,
           "org" => org,
           "url_auth" => attrs["url_auth"],
           "release" => "0.1.0",
           "workspace" => "/home/sprite/project",
           "port" => 8080,
           "repository" =>
             if(repository == "", do: nil, else: %{"url" => repository, "ref" => ref}),
           "env" => [],
           "bootstrap" => [],
           "bootstrap_timeout_seconds" => 900,
           "cors_origins" => [],
           "agent" => %{
             "runtime" => runtime,
             "name" => display,
             "model" => if(model == "", do: nil, else: model),
             "instructions" => if(instructions == "", do: nil, else: instructions),
             "permissions" => %{"default" => attrs["permissions"]}
           }
         }}
    end
  end

  defp repository?(url) do
    uri = URI.parse(url)

    uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
      is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
      byte_size(url) <= 2048
  rescue
    _ -> false
  end
end
