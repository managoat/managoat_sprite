defmodule Managoat.Sprite.ProviderFailure do
  @moduledoc "Safe failure codes from known structured provider reports."
  def reason(data) when is_binary(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case Jason.decode(line) do
        {:ok,
         %{
           "method" => "session/update",
           "params" => %{
             "update" => %{
               "sessionUpdate" => "session_info_update",
               "_meta" => %{"codex" => %{"error" => error}}
             }
           }
         }}
        when is_map(error) ->
          details =
            [error["message"], error["additionalDetails"]]
            |> Enum.filter(&is_binary/1)
            |> Enum.join(" ")
            |> String.downcase()

          cond do
            String.contains?(details, [
              "add credits",
              "insufficient_quota",
              "credit balance",
              "billing_hard_limit_reached"
            ]) ->
              "provider_billing_error"

            error["willRetry"] == false ->
              "provider_error"

            true ->
              nil
          end

        _ ->
          nil
      end
    end)
  end

  def reason(_), do: nil
end
