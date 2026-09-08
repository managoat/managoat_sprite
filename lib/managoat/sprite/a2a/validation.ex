defmodule Managoat.Sprite.A2A.Validation do
  @moduledoc false
  @states ~w(TASK_STATE_SUBMITTED TASK_STATE_WORKING TASK_STATE_COMPLETED TASK_STATE_FAILED TASK_STATE_CANCELED TASK_STATE_INPUT_REQUIRED TASK_STATE_REJECTED TASK_STATE_AUTH_REQUIRED)
  def params(method, p) when is_map(p) do
    allowed =
      case method do
        m when m in ~w(SendMessage SendStreamingMessage) ->
          ~w(message configuration metadata tenant)

        "GetTask" ->
          ~w(id historyLength tenant)

        "ListTasks" ->
          ~w(contextId status pageSize pageToken historyLength statusTimestampAfter includeArtifacts tenant)

        "CancelTask" ->
          ~w(id metadata tenant)

        "SubscribeToTask" ->
          ~w(id tenant)

        _ ->
          []
      end

    cond do
      Map.keys(p) -- allowed != [] -> invalid("unsupported_parameter")
      p["tenant"] not in [nil, ""] -> invalid("unsupported_tenant")
      Map.has_key?(p, "metadata") and not is_map(p["metadata"]) -> invalid("invalid_metadata")
      not nonnegative?(p["historyLength"]) -> invalid("invalid_history_length")
      method in ~w(SendMessage SendStreamingMessage) -> send_params(p)
      method == "ListTasks" -> list_params(p)
      not id?(p["id"]) -> invalid("task_id_required")
      true -> :ok
    end
  end

  def params(_, _), do: invalid("invalid_params")

  defp send_params(p) do
    m = p["message"]
    c = Map.get(p, "configuration", %{})

    cond do
      not is_map(m) or not is_map(c) ->
        invalid("message_required")

      Map.keys(m) --
        ~w(messageId contextId taskId role parts metadata extensions referenceTaskIds) != [] ->
        invalid("invalid_message")

      Map.keys(c) --
        ~w(acceptedOutputModes taskPushNotificationConfig historyLength returnImmediately) != [] ->
        invalid("invalid_configuration")

      Map.has_key?(c, "taskPushNotificationConfig") ->
        {:error, {-32003, "push_notifications_not_supported"}}

      not nonnegative?(c["historyLength"]) or c["returnImmediately"] not in [nil, false, true] ->
        invalid("invalid_configuration")

      not output_modes?(c["acceptedOutputModes"]) ->
        {:error, {-32005, "text_output_required"}}

      not id?(m["messageId"]) or m["role"] != "ROLE_USER" ->
        invalid("invalid_message")

      Enum.any?(~w(contextId taskId), &(Map.has_key?(m, &1) and not id?(m[&1]))) ->
        invalid("invalid_message_context")

      Map.has_key?(m, "metadata") and not is_map(m["metadata"]) ->
        invalid("invalid_metadata")

      m["extensions"] not in [nil, []] or m["referenceTaskIds"] not in [nil, []] ->
        {:error, {-32004, "extensions_not_supported"}}

      not is_list(m["parts"]) or m["parts"] == [] ->
        invalid("parts_required")

      not Enum.all?(m["parts"], &text_part?/1) ->
        {:error, {-32005, "text_parts_only"}}

      Enum.all?(m["parts"], &(String.trim(&1["text"]) == "")) ->
        invalid("text_required")

      true ->
        :ok
    end
  end

  defp list_params(p) do
    cond do
      p["contextId"] != nil and not id?(p["contextId"]) ->
        invalid("invalid_context")

      p["status"] != nil and p["status"] not in @states ->
        invalid("invalid_status")

      p["pageSize"] != nil and not (is_integer(p["pageSize"]) and p["pageSize"] in 1..100) ->
        invalid("invalid_page_size")

      p["pageToken"] != nil and
          not (is_binary(p["pageToken"]) and byte_size(p["pageToken"]) <= 2048) ->
        invalid("invalid_page_token")

      p["includeArtifacts"] not in [nil, true, false] ->
        invalid("invalid_include_artifacts")

      not timestamp?(p["statusTimestampAfter"]) ->
        invalid("invalid_timestamp")

      true ->
        :ok
    end
  end

  defp text_part?(p) when is_map(p),
    do:
      Map.keys(p) -- ~w(text mediaType metadata) == [] and is_binary(p["text"]) and
        p["mediaType"] in [nil, "text/plain"] and
        (not Map.has_key?(p, "metadata") or is_map(p["metadata"]))

  defp text_part?(_), do: false
  defp output_modes?(nil), do: true
  defp output_modes?([]), do: true
  defp output_modes?(m), do: is_list(m) and Enum.all?(m, &is_binary/1) and "text/plain" in m
  defp nonnegative?(nil), do: true
  defp nonnegative?(v), do: is_integer(v) and v >= 0 and v <= 2_147_483_647
  defp id?(v), do: is_binary(v) and byte_size(v) in 1..256 and not String.contains?(v, <<0>>)
  defp timestamp?(nil), do: true
  defp timestamp?(v) when is_binary(v), do: match?({:ok, _, _}, DateTime.from_iso8601(v))
  defp timestamp?(_), do: false
  defp invalid(reason), do: {:error, {-32602, reason}}
end
