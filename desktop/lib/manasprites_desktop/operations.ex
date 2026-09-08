defmodule ManaspritesDesktop.Operations do
  @moduledoc false
  alias ManaspritesDesktop.{Agent, Fleet, Repo, ServiceClient}

  def run(job) do
    agent = Fleet.get(job.agent_id)

    result =
      case job.kind do
        "workspace" ->
          ManaspritesDesktop.Workspace.run(agent, job.payload)

        "connect" ->
          connect(agent)

        "sync" ->
          sync(agent.id, job.payload["conversation_id"])

        "prompt" ->
          cid = job.payload["conversation_id"]
          path = if cid, do: "/api/conversations/#{cid}/prompts", else: "/api/conversations"

          with {:ok, response} <-
                 ServiceClient.request(
                   agent,
                   :post,
                   path,
                   %{"prompt" => job.payload["prompt"]},
                   job.id
                 ) do
            cid = cid || get_in(response, ["data", "id"])

            if Fleet.valid_id?(cid) do
              # The mutation is acknowledged even if subsequent history refresh fails.
              sync(agent.id, cid)
              {:ok, %{"conversation_id" => cid}}
            else
              {:error, :invalid_response}
            end
          end

        "interrupt" ->
          with {:ok, _} <-
                 ServiceClient.request(
                   agent,
                   :post,
                   "/api/conversations/#{job.payload["conversation_id"]}/interrupt",
                   %{}
                 ) do
            sync(agent.id, job.payload["conversation_id"])
            {:ok, %{}}
          end

        "permission" ->
          p = job.payload

          with {:ok, _} <-
                 ServiceClient.request(
                   agent,
                   :post,
                   "/api/conversations/#{p["conversation_id"]}/requests/#{URI.encode(p["request_id"], &URI.char_unreserved?/1)}",
                   %{"option_id" => p["option_id"]}
                 ) do
            sync(agent.id, p["conversation_id"])
            {:ok, %{}}
          end
      end

    if job.kind != "workspace" and match?({:error, _}, result),
      do: mark_error(agent.id, elem(result, 1))

    result
  rescue
    _ -> {:error, :connection_failed}
  end

  defp connect(agent) do
    with {:ok, agent} <- bind_private(agent),
         {:ok, %{"contract" => "fountain-conversations-v1"}} <-
           ServiceClient.request(agent, :get, "/api/capabilities"),
         {:ok, %{"data" => [%{"id" => "default", "runtime" => runtime} = remote]}} <-
           ServiceClient.request(agent, :get, "/api/agents") do
      current = Repo.get!(Agent, agent.id)

      Repo.update!(
        Ecto.Changeset.change(current,
          runtime: runtime,
          workspace: remote["workspace"] || current.workspace,
          status: "ready",
          error: nil
        )
      )

      sync(agent.id, nil)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_response}
    end
  end

  defp bind_private(%{transport: "private", sprite_id: nil} = agent) do
    alias ManaspritesDesktop.{PlatformClient, Vault}

    with {:ok, token} <- Vault.get("sprites"),
         [org, _, _] when org == agent.organization <- String.split(token, "/", parts: 3),
         {:ok, info} <- PlatformClient.info(token, agent.sprite_name),
         true <-
           info["name"] == agent.sprite_name and info["organization"] == agent.organization and
             is_binary(info["id"]) do
      Repo.update(Ecto.Changeset.change(agent, sprite_id: info["id"]))
    else
      _ -> {:error, :private_connection}
    end
  end

  defp bind_private(agent), do: {:ok, agent}

  def sync(aid, selected) do
    agent = Fleet.get(aid)

    result =
      with {:ok, %{"data" => conversations}} when is_list(conversations) <-
             ServiceClient.request(agent, :get, "/api/conversations") do
        # Include conversations that were active at the previous snapshot so a
        # terminal list response cannot strand their final events in the Sprite.
        active =
          Enum.filter(
            conversations ++ Fleet.conversations(agent),
            &(&1["status"] in ~w(pending running))
          )

        targets = Enum.uniq(List.wrap(selected) ++ Enum.map(active, & &1["id"]))

        result =
          Enum.reduce_while(targets, :ok, fn cid, _ ->
            if Fleet.valid_id?(cid) do
              case history(agent, cid) do
                :ok -> {:cont, :ok}
                error -> {:halt, error}
              end
            else
              {:halt, {:error, :invalid_response}}
            end
          end)

        case result do
          :ok ->
            status =
              if Enum.any?(conversations, &(&1["status"] in ~w(pending running))),
                do: "working",
                else: "ready"

            agent = Repo.get!(Agent, aid)

            Repo.update!(
              Ecto.Changeset.change(agent,
                snapshot: %{"conversations" => conversations},
                status: status,
                error: nil,
                checked_at: DateTime.utc_now()
              )
            )

            {:ok, %{}}

          error ->
            error
        end
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_response}
      end

    if match?({:error, _}, result), do: mark_error(aid, elem(result, 1))
    result
  rescue
    _ ->
      mark_error(aid, :invalid_response)
      {:error, :invalid_response}
  end

  defp history(agent, cid) do
    with {:ok, %{"data" => turns}} when is_list(turns) <-
           ServiceClient.request(agent, :get, "/api/conversations/#{cid}/turns"),
         :ok <- pages(agent, cid, Fleet.cursor(agent.id, cid), 100) do
      Fleet.cache_turns(agent.id, cid, turns)
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_response}
    end
  end

  defp pages(_, _, _, 0), do: {:error, :response_limit}

  defp pages(agent, cid, cursor, remaining) do
    with {:ok, %{"data" => events, "meta" => meta}} when is_list(events) <-
           ServiceClient.request(
             agent,
             :get,
             "/api/conversations/#{cid}/events?blocks=true&after=#{cursor}&limit=1000"
           ) do
      if Enum.all?(events, &(is_integer(&1["id"]) and &1["id"] > cursor)) do
        Fleet.cache_events(agent.id, cid, events)

        if meta["has_more"] do
          next = meta["next_cursor"]

          if is_integer(next) and next > cursor,
            do: pages(agent, cid, next, remaining - 1),
            else: {:error, :invalid_response}
        else
          :ok
        end
      else
        {:error, :invalid_response}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_response}
    end
  end

  defp mark_error(aid, error) do
    if agent = Fleet.get(aid),
      do:
        Repo.update!(
          Ecto.Changeset.change(agent, status: "attention", error: ServiceClient.message(error))
        )
  end
end
