defmodule Managoat.Sprite.A2A.Card do
  @moduledoc "Sanitized discovery from explicitly verified operator configuration."
  alias Managoat.Sprite.Config
  @path "/.well-known/agent-card.json"

  def validate!(value) do
    defaults = %{
      "enabled" => false,
      "external_origin" => nil,
      "origin_verified" => false,
      "ingress" => "private"
    }

    unless is_map(value) and Map.keys(value) -- Map.keys(defaults) == [],
      do: raise(ArgumentError, "invalid a2a configuration")

    c = Map.merge(defaults, value)

    unless is_boolean(c["enabled"]) and is_boolean(c["origin_verified"]) and
             c["ingress"] in ~w(public private),
           do: raise(ArgumentError, "invalid a2a configuration")

    unless is_nil(c["external_origin"]) or valid_origin?(c["external_origin"]),
      do: raise(ArgumentError, "a2a requires an external HTTPS origin without credentials")

    if c["origin_verified"] and is_nil(c["external_origin"]),
      do: raise(ArgumentError, "a2a verified origin missing")

    c
  end

  def valid_origin?(origin) when is_binary(origin) do
    u = URI.parse(origin)
    host = String.downcase(u.host || "")

    u.scheme == "https" and host != "" and u.userinfo == nil and u.path in [nil, ""] and
      u.query == nil and u.fragment == nil and u.port in 1..65535 and
      Regex.match?(~r/\A[a-z0-9][a-z0-9.-]*[a-z0-9]\z/, host) and String.contains?(host, ".") and
      not String.ends_with?(host, [".localhost", ".local", ".internal"]) and public_host?(host)
  rescue
    _ -> false
  end

  def valid_origin?(_), do: false

  defp public_host?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {a, b, _, _}} ->
        a not in [0, 10, 127, 169] and not (a == 172 and b in 16..31) and
          not (a == 192 and b == 168) and a < 224

      {:ok, _} ->
        false

      _ ->
        true
    end
  end

  def metadata do
    c = Config.get()["a2a"]
    ready = c["enabled"] and c["origin_verified"] and is_binary(c["external_origin"])

    %{
      "enabled" => c["enabled"],
      "protocol_version" => "1.0",
      "card_url" => if(ready, do: c["external_origin"] <> @path),
      "state" =>
        cond do
          not c["enabled"] -> "disabled"
          ready -> "ready"
          true -> "configuration_needed"
        end,
      "ingress" => c["ingress"],
      "authentication" => "bearer",
      "authority" => "owner"
    }
  end

  def available?, do: metadata()["state"] == "ready"
  def enabled?, do: Config.get()["a2a"]["enabled"]

  def document do
    %{
      name: "Manasprites workspace agent",
      description:
        "Coding tasks for trusted peers acting as the owner. Credentials are configured separately.",
      version: to_string(Application.spec(:managoat_sprite, :vsn)),
      supportedInterfaces: [
        %{
          url: Config.get()["a2a"]["external_origin"] <> "/a2a",
          protocolBinding: "JSONRPC",
          protocolVersion: "1.0"
        }
      ],
      capabilities: %{streaming: true, pushNotifications: false, extendedAgentCard: false},
      securitySchemes: %{bearer: %{httpAuthSecurityScheme: %{scheme: "Bearer"}}},
      securityRequirements: [%{schemes: %{bearer: %{list: []}}}],
      defaultInputModes: ["text/plain"],
      defaultOutputModes: ["text/plain"],
      skills: [
        %{
          id: "coding",
          name: "Coding",
          description: "Carry out coding tasks and return text results.",
          tags: ["coding"]
        }
      ]
    }
  end
end
