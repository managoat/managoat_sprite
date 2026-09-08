defmodule ManaspritesDesktop.A2ADiscovery do
  @moduledoc "Presentation of cached service discovery; never constructs a remote origin."
  def for_agent(agent) do
    a2a = get_in(agent.snapshot, ["capabilities", "a2a"])

    cond do
      not is_map(a2a) ->
        %{status: "Upgrade required", url: nil, private?: agent.transport == "private"}

      a2a["enabled"] != true ->
        %{status: "Not enabled", url: nil, private?: agent.transport == "private"}

      a2a["state"] != "ready" or not valid_url?(a2a["card_url"]) ->
        %{status: "Configuration needed", url: nil, private?: agent.transport == "private"}

      true ->
        %{
          status: "Agent card URL",
          url: a2a["card_url"],
          private?: a2a["ingress"] != "public" or agent.transport == "private"
        }
    end
  end

  defp valid_url?(url) when is_binary(url) do
    u = URI.parse(url)
    host = String.downcase(u.host || "")

    u.scheme == "https" and u.path == "/.well-known/agent-card.json" and u.userinfo == nil and
      u.query == nil and u.fragment == nil and host not in ["", "localhost"] and
      not String.ends_with?(host, [".localhost", ".local", ".internal"]) and
      String.contains?(host, ".") and
      not match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))
  rescue
    _ -> false
  end

  defp valid_url?(_), do: false
end
