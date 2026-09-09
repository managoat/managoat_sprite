defmodule ManaspritesDesktop.PlatformClient do
  @moduledoc "Sprites REST API with bounded responses and explicit mutation retry."
  @limit 4 * 1024 * 1024
  def base_url,
    do: Application.get_env(:manasprites_desktop, :platform_url, "https://api.sprites.dev")

  def name?(name), do: is_binary(name) and Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,62}\z/, name)

  def request(token, method, path, body \\ nil) do
    case Req.request(
           url: base_url() <> path,
           method: method,
           headers: [{"authorization", "Bearer " <> token}, {"content-type", "application/json"}],
           body: if(body, do: Jason.encode!(body)),
           retry: false,
           redirect: false,
           decode_body: false,
           receive_timeout: 120_000,
           connect_options: [timeout: 10_000],
           into: fn {:data, data}, {req, resp} ->
             current = resp.body || ""

             if byte_size(current) + byte_size(data) > @limit,
               do: {:halt, {req, Req.Response.put_private(resp, :too_large, true)}},
               else: {:cont, {req, %{resp | body: current <> data}}}
           end
         ) do
      {:ok, %{private: %{too_large: true}}} ->
        {:error, :platform_response_limit}

      {:ok, %{status: status, body: raw}} when status in 200..299 ->
        case Jason.decode(if(raw in [nil, ""], do: "{}", else: raw)) do
          {:ok, data} when is_map(data) or is_list(data) -> {:ok, data}
          _ -> {:error, :platform_response_invalid}
        end

      {:ok, %{status: status}} ->
        {:error, {:platform_http, status}}

      _ ->
        {:error, :platform_unreachable}
    end
  rescue
    _ -> {:error, :platform_unreachable}
  end

  def list(token), do: page(token, nil, MapSet.new(), [], 100)
  def info(token, name), do: request(token, :get, "/v1/sprites/" <> name)

  defp page(_, _, _, _, 0), do: {:error, :platform_response_limit}

  defp page(token, cursor, seen, rows, left) do
    query =
      URI.encode_query(
        if cursor,
          do: [{"continuation_token", cursor}, {"max_results", 500}],
          else: [{"max_results", 500}]
      )

    with {:ok, data} <- request(token, :get, "/v1/sprites?" <> query) do
      entries = if is_list(data), do: data, else: data["sprites"]
      more = is_map(data) and data["has_more"] == true
      next = if is_map(data), do: data["next_continuation_token"]

      cond do
        not is_list(entries) or not Enum.all?(entries, &(is_map(&1) and name?(&1["name"]))) ->
          {:error, :platform_response_invalid}

        more and (not is_binary(next) or next == "" or MapSet.member?(seen, next)) ->
          {:error, :platform_response_invalid}

        more ->
          page(token, next, MapSet.put(seen, next), rows ++ entries, left - 1)

        true ->
          {:ok,
           Enum.uniq_by(rows ++ entries, &{&1["organization"] || &1["org_slug"], &1["name"]})}
      end
    end
  end

  def message({:platform_http, 401}),
    do: "The Sprites token was rejected. Save a valid token in settings."

  def message({:platform_http, 403}), do: "The Sprites token does not permit this operation."

  def message({:platform_http, code}),
    do: "Sprites returned HTTP #{code}. Review this operation before retrying."

  def message(:sprite_conflict),
    do: "This name belongs to a different Sprite. It was left unchanged."

  def message(:sprite_missing),
    do: "The recorded Sprite is gone. Use a new name to create a replacement."

  def message(:wrong_organization),
    do: "The token belongs to a different organization. No setup was performed."

  def message(:platform_response_invalid),
    do: "Sprites returned an unexpected response. Refresh before retrying."

  def message(:platform_response_limit), do: "The Sprites response exceeded the local size limit."

  def message(:credential_missing),
    do: "A required saved key is missing. Save it in settings before continuing."

  def message({:remote_setup, code}),
    do: "Remote setup stopped (#{code}). Inspect the Sprite's private setup logs before retrying."

  def message(:remote_unavailable),
    do:
      "The Sprite command disconnected or timed out. Setup may still be running; review before retrying."

  def message(:verification_failed),
    do:
      "The service is installed but its endpoint is not verified. Retry after checking Sprite networking."

  def message(_), do: "Could not finish the Sprite operation. Review its state before retrying."
end
