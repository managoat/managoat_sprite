defmodule ManaspritesDesktop.ProviderDiagnostics do
  @moduledoc "Fixed user-facing warnings derived from structured provider error reports."

  def warning(data) when is_binary(data) do
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
          classify(error)

        _ ->
          nil
      end
    end)
  end

  def warning(_), do: nil

  defp classify(error) do
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
        "The provider reported a billing or credit error. Check the provider account and review this turn before retrying."

      error["willRetry"] == false ->
        "The provider reported an error without an automatic retry. Review this turn before submitting more work."

      true ->
        nil
    end
  end
end
