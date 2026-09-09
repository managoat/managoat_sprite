defmodule ManaspritesDesktop.ServiceClient do
  @moduledoc "Bounded service requests, without redirects or automatic mutation retries."
  @limit 16 * 1024 * 1024
  alias ManaspritesDesktop.{PlatformClient, PrivateProxy, Vault}

  def valid_origin?(url) when is_binary(url) do
    uri = URI.parse(url)

    is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) and
      uri.path in [nil, ""] and is_nil(uri.query) and is_nil(uri.fragment) and
      (uri.scheme == "https" or
         (uri.scheme == "http" and uri.host in ["127.0.0.1", "localhost", "::1"]))
  rescue
    _ -> false
  end

  def valid_origin?(_), do: false

  def request(agent, method, path, body \\ nil, idempotency \\ nil) do
    with {:ok, key} <- Vault.get("agent:" <> agent.id) do
      if agent.transport == "private" do
        with {:ok, token} <- Vault.get("sprites"),
             [org, _, _] when org == agent.organization <- String.split(token, "/", parts: 3),
             true <- PlatformClient.name?(agent.sprite_name),
             {:ok, info} <- PlatformClient.info(token, agent.sprite_name),
             true <-
               info["id"] == agent.sprite_id and info["name"] == agent.sprite_name and
                 info["organization"] == agent.organization do
          PrivateProxy.with_url(token, agent.sprite_name, agent.port, fn url ->
            request_with_key(url, key, method, path, body, idempotency)
          end)
        else
          _ -> {:error, :private_connection}
        end
      else
        request_with_key(agent.url, key, method, path, body, idempotency)
      end
    end
  end

  def request_with_key(url, key, method, path, body \\ nil, idempotency \\ nil) do
    headers = [
      {"authorization", "Bearer " <> key},
      {"content-type", "application/json"},
      {"connection", "close"}
    ]

    headers = if idempotency, do: [{"idempotency-key", idempotency} | headers], else: headers

    opts = [
      url: url <> path,
      method: method,
      headers: headers,
      body: if(body, do: Jason.encode!(body)),
      redirect: false,
      retry: false,
      decode_body: false,
      receive_timeout: 60_000,
      connect_options: [timeout: 10_000],
      into: fn {:data, data}, {req, resp} ->
        current = resp.body || ""

        if byte_size(current) + byte_size(data) > @limit do
          {:halt, {req, Req.Response.put_private(resp, :too_large, true)}}
        else
          {:cont, {req, %{resp | body: current <> data}}}
        end
      end
    ]

    case Req.request(opts) do
      {:ok, response} -> decode(response)
      {:error, _} -> {:error, :connection_failed}
    end
  rescue
    _ -> {:error, :connection_failed}
  end

  defp decode(%{private: %{too_large: true}}), do: {:error, :response_limit}

  defp decode(%{status: status, body: body}) when status in 200..299 do
    if body in [nil, ""] do
      {:ok, %{}}
    else
      case Jason.decode(body) do
        {:ok, value} when is_map(value) -> {:ok, value}
        _ -> {:error, :invalid_response}
      end
    end
  end

  defp decode(%{status: status}), do: {:error, {:http, status}}

  def message({:http, 401}), do: "The service rejected its bearer key. Update the connection key."

  def message({:http, 409}),
    do: "Another turn is active, or this request conflicts with earlier work."

  def message({:http, 410}), do: "This conversation has been closed."

  def message({:http, code}),
    do: "The service returned HTTP #{code}. Refresh before trying again."

  def message(:credential_missing),
    do: "The saved service key is missing. Update this connection."

  def message(:invalid_response),
    do: "This endpoint did not return the expected Manasprites response."

  def message(:response_limit), do: "The service response exceeded the local size limit."

  def message(:private_connection),
    do:
      "Check the saved Sprites token and Sprite identity. The private connection could not be verified."

  def message(_), do: "Could not reach the agent. Remote work may still be running."
end
