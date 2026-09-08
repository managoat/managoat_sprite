defmodule ManaspritesDesktopWeb.FleetLive do
  use Phoenix.LiveView
  alias ManaspritesDesktop.{Fleet, Preferences, Vault, Platform, PlatformClient, Workspace}

  @impl true
  def mount(_, _, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ManaspritesDesktop.PubSub, "fleet")
      ManaspritesDesktop.Shell.report_live(Preferences.workspace_name())
    end

    {:ok,
     socket
     |> assign(
       name: Preferences.workspace_name(),
       settings: false,
       connecting: false,
       connection_kind: "direct",
       connection_defaults: %{},
       platform_open: false,
       selected: nil,
       conversation_id: nil,
       pending_prompt: nil,
       form: to_form(%{}),
       confirm_remove: false,
       history_limit: 2000,
       inspector_tab: "files",
       inspector_action: "list",
       inspector_path: "",
       inspector_staged: false,
       inspector_job: nil,
       inspector_wide: false
     )
     |> refresh()}
  end

  @impl true
  def handle_event("settings", _, socket),
    do: {:noreply, assign(socket, settings: !socket.assigns.settings)}

  def handle_event("connect_form", _, socket),
    do:
      {:noreply,
       assign(socket,
         connecting: !socket.assigns.connecting,
         connection_kind: "direct",
         connection_defaults: %{}
       )}

  def handle_event("connection_kind", %{"transport" => kind}, socket)
      when kind in ~w(direct private),
      do: {:noreply, assign(socket, connection_kind: kind)}

  def handle_event("connect_discovered", %{"name" => name, "organization" => org}, socket) do
    if PlatformClient.name?(name) and PlatformClient.name?(org) do
      {:noreply,
       assign(socket,
         connecting: true,
         platform_open: false,
         settings: false,
         connection_kind: "private",
         connection_defaults: %{"name" => name, "sprite_name" => name, "organization" => org}
       )}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "This Sprite is missing a valid name or organization. Refresh discovery."
       )}
    end
  end

  def handle_event("platform", _, socket),
    do: {:noreply, assign(socket, platform_open: !socket.assigns.platform_open)}

  def handle_event("discover_sprites", _, socket) do
    platform_result(socket, Platform.discover())
  end

  def handle_event("create_sprite", params, socket) do
    platform_result(socket, Platform.create(params))
  end

  def handle_event("retry_platform", %{"id" => id}, socket) do
    case Platform.retry(id) do
      :ok -> {:noreply, refresh(socket)}
      {:error, error} -> {:noreply, put_flash(socket, :error, PlatformClient.message(error))}
    end
  end

  def handle_event("overview", _, socket),
    do: {:noreply, socket |> assign(selected: nil, conversation_id: nil) |> refresh()}

  def handle_event("inspector_tab", %{"tab" => tab}, socket)
      when tab in ~w(files changes requests) do
    {:noreply,
     socket
     |> assign(
       inspector_tab: tab,
       inspector_action: if(tab == "changes", do: "status", else: "list"),
       inspector_path: "",
       inspector_staged: false,
       inspector_job: nil
     )
     |> refresh()}
  end

  def handle_event("inspector_width", _, socket),
    do: {:noreply, assign(socket, inspector_wide: !socket.assigns.inspector_wide)}

  def handle_event("inspect_workspace", params, socket) do
    inspect_workspace(socket, %{
      "action" => params["action"],
      "path" => params["path"] || "",
      "staged" => params["staged"] == "true"
    })
  end

  def handle_event("refresh_inspector", _, socket) do
    inspect_workspace(socket, %{
      "action" =>
        if(socket.assigns.inspector_action == "link",
          do: "list",
          else: socket.assigns.inspector_action
        ),
      "path" => socket.assigns.inspector_path,
      "staged" => socket.assigns.inspector_staged
    })
  end

  def handle_event("link_workspace", params, socket) do
    inspect_workspace(
      socket,
      Map.merge(Map.take(params, ~w(sprite_name organization)), %{
        "action" => "link",
        "path" => ""
      })
    )
  end

  def handle_event("rename", %{"name" => name}, socket) do
    case Preferences.rename_workspace(name) do
      :ok ->
        ManaspritesDesktop.Shell.report_live(Preferences.workspace_name())

        {:noreply,
         socket
         |> assign(name: Preferences.workspace_name(), settings: false)
         |> put_flash(:info, "Workspace saved on this laptop.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Use a workspace name between 1 and 100 bytes.")}
    end
  end

  def handle_event("save_credential", %{"provider" => provider, "secret" => secret}, socket) do
    if provider in Vault.providers() and Vault.put(provider, secret) == :ok do
      {:noreply,
       socket
       |> refresh()
       |> push_event("clear-secrets", %{})
       |> put_flash(:info, "Key saved on this laptop.")}
    else
      {:noreply, put_flash(socket, :error, "Enter a supported, single-line API key.")}
    end
  end

  def handle_event("remove_credential", %{"provider" => provider}, socket) do
    if provider in Vault.providers(), do: Vault.delete(provider)
    {:noreply, refresh(socket)}
  end

  def handle_event("attach", params, socket) do
    case Fleet.attach(
           Map.take(params, ~w(name url organization transport sprite_name port)),
           params["secret"]
         ) do
      {:ok, aid} ->
        {:noreply,
         socket
         |> assign(
           selected: aid,
           connecting: false,
           platform_open: false,
           settings: false,
           conversation_id: nil,
           inspector_job: nil,
           inspector_action: "list",
           inspector_path: "",
           inspector_staged: false,
           inspector_tab: "files"
         )
         |> refresh()
         |> push_event("clear-secrets", %{})}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Check the connection fields and service key. Each service address can appear once in your fleet."
         )}
    end
  end

  def handle_event("select_agent", %{"id" => id}, socket) do
    if agent = Fleet.get(id) do
      conversations = Fleet.conversations(agent)

      conversation =
        Enum.find(conversations, &(&1["status"] in ~w(pending running))) ||
          List.first(conversations)

      cid = if conversation, do: conversation["id"]
      Fleet.submit(id, "sync", %{"conversation_id" => cid})

      {:noreply,
       socket
       |> assign(
         selected: id,
         platform_open: false,
         connecting: false,
         settings: false,
         conversation_id: cid,
         history_limit: 2000,
         confirm_remove: false,
         pending_prompt: nil,
         inspector_job: nil,
         inspector_action: "list",
         inspector_path: "",
         inspector_staged: false,
         inspector_tab: "files"
       )
       |> refresh()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_conversation", %{"id" => cid}, socket) do
    if Fleet.valid_id?(cid) do
      Fleet.submit(socket.assigns.selected, "sync", %{"conversation_id" => cid})
      {:noreply, socket |> assign(conversation_id: cid, history_limit: 2000) |> refresh()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("new_conversation", _, socket),
    do: {:noreply, socket |> assign(conversation_id: nil) |> refresh()}

  def handle_event("refresh_agent", _, socket) do
    queue(socket, "sync", %{"conversation_id" => socket.assigns.conversation_id})
  end

  def handle_event("refresh_fleet", _, socket) do
    Enum.each(Fleet.list(), &Fleet.submit(&1.id, "sync", %{}))
    {:noreply, put_flash(socket, :info, "Refreshing your fleet.")}
  end

  def handle_event("prompt", %{"prompt" => prompt}, socket) do
    case Fleet.submit(socket.assigns.selected, "prompt", %{
           "prompt" => prompt,
           "conversation_id" => socket.assigns.conversation_id
         }) do
      {:ok, job} ->
        {:noreply,
         socket |> assign(pending_prompt: job.id) |> refresh() |> push_event("clear-prompt", %{})}

      _ ->
        {:noreply,
         put_flash(socket, :error, "Review any pending submission, and enter a nonempty prompt.")}
    end
  end

  def handle_event("interrupt", _, socket),
    do: queue(socket, "interrupt", %{"conversation_id" => socket.assigns.conversation_id})

  def handle_event("permission", %{"request" => rid, "option" => option}, socket) do
    queue(socket, "permission", %{
      "conversation_id" => socket.assigns.conversation_id,
      "request_id" => rid,
      "option_id" => option
    })
  end

  def handle_event("update_key", %{"secret" => key}, socket) do
    case Fleet.update_key(socket.assigns.selected, key) do
      {:ok, _} -> {:noreply, socket |> refresh() |> push_event("clear-secrets", %{})}
      _ -> {:noreply, put_flash(socket, :error, "Enter a valid service bearer key.")}
    end
  end

  def handle_event("reviewed", %{"id" => id}, socket) do
    Fleet.resolve_unknown(socket.assigns.selected, id)
    {:noreply, refresh(socket)}
  end

  def handle_event("remove_agent", _, socket),
    do: {:noreply, assign(socket, confirm_remove: true)}

  def handle_event("cancel_remove", _, socket),
    do: {:noreply, assign(socket, confirm_remove: false)}

  def handle_event("confirm_remove", _, socket) do
    case Fleet.remove(socket.assigns.selected) do
      :ok ->
        {:noreply,
         socket |> assign(selected: nil, conversation_id: nil, confirm_remove: false) |> refresh()}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Wait for the local request to finish before removing this connection."
         )}
    end
  end

  def handle_event("more_history", _, socket),
    do:
      {:noreply,
       socket |> assign(history_limit: socket.assigns.history_limit + 2000) |> refresh()}

  defp platform_result(socket, {:ok, _}),
    do: {:noreply, socket |> refresh() |> assign(platform_open: true)}

  defp platform_result(socket, {:error, error}) do
    message =
      case error do
        :invalid_config ->
          "Check the Sprite name, organization, runtime and repository. Choose the endpoint access setting."

        %Ecto.Changeset{} ->
          "This Sprite already has a creation record. Resume that operation instead."

        _ ->
          PlatformClient.message(error)
      end

    {:noreply, put_flash(socket, :error, message)}
  end

  defp queue(socket, kind, payload) do
    case Fleet.submit(socket.assigns.selected, kind, payload) do
      {:ok, _} ->
        {:noreply, refresh(socket)}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Could not submit this request. Refresh the agent and try again."
         )}
    end
  end

  defp inspect_workspace(socket, payload) do
    case Fleet.submit(socket.assigns.selected, "workspace", payload) do
      {:ok, job} ->
        {:noreply,
         socket
         |> assign(
           inspector_job: job.id,
           inspector_action: payload["action"],
           inspector_path: payload["path"],
           inspector_staged: payload["staged"] == true
         )
         |> refresh()}

      _ ->
        {:noreply, put_flash(socket, :error, "Choose a valid project path or Sprite connection.")}
    end
  end

  @impl true
  def handle_info(:changed, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    agent = socket.assigns.selected && Fleet.get(socket.assigns.selected)
    jobs = if agent, do: Fleet.jobs(agent.id), else: []
    pending = Enum.find(jobs, &(&1.id == socket.assigns.pending_prompt))

    cid =
      if pending && pending.state == "completed",
        do: pending.result["conversation_id"] || socket.assigns.conversation_id,
        else: socket.assigns.conversation_id

    all_events =
      if agent && cid,
        do: Fleet.events(agent.id, cid, socket.assigns.history_limit + 1),
        else: []

    events = Enum.take(all_events, -socket.assigns.history_limit)
    turns = if agent && cid, do: Fleet.turns(agent.id, cid), else: []

    entries =
      Enum.map(turns, fn turn ->
        blocks =
          events
          |> Enum.filter(&(&1["turn_id"] == turn["id"]))
          |> Enum.flat_map(&(&1["blocks"] || []))

        # Join adjacent text chunks while keeping tools in their original position.
        blocks =
          blocks
          |> Enum.chunk_by(&(&1["kind"] == "text"))
          |> Enum.flat_map(fn
            [%{"kind" => "text"} | _] = group ->
              [%{"kind" => "text", "body" => Enum.map_join(group, &(&1["body"] || ""))}]

            group ->
              Enum.map(group, fn block ->
                if block["kind"] == "permission_request",
                  do:
                    Map.put(
                      block,
                      "answered_locally",
                      Fleet.permission_answered?(agent.id, cid, block["request_id"])
                    ),
                  else: block
              end)
          end)

        %{turn: turn, blocks: blocks}
      end)

    agents = Fleet.list()
    approvals = Map.new(agents, &{&1.id, Fleet.approval_requested?(&1)})
    provider_warnings = Map.new(agents, &{&1.id, Fleet.provider_warning?(&1)})
    attention = Map.new(agents, &{&1.id, approvals[&1.id] || provider_warnings[&1.id]})

    assign(socket,
      name: Preferences.workspace_name(),
      agents: agents,
      approvals: approvals,
      provider_warnings: provider_warnings,
      attention: attention,
      attention_count: Enum.count(agents, &(fleet_lane(&1, attention) == "attention")),
      agent: agent,
      providers: Vault.presence(),
      platform_jobs: Platform.jobs(),
      conversation_id: cid,
      jobs: jobs,
      entries: entries,
      pending_prompt:
        if(pending && pending.state == "completed", do: nil, else: socket.assigns.pending_prompt),
      pending?: agent && Fleet.prompt_pending?(agent.id),
      busy?: agent && Fleet.busy?(agent),
      history_more?: length(all_events) > length(events),
      inspection: if(agent, do: inspection(socket, agent.id))
    )
  end

  defp inspection(socket, aid) do
    if socket.assigns.inspector_job,
      do: Workspace.job(aid, socket.assigns.inspector_job),
      else:
        Workspace.latest(
          aid,
          socket.assigns.inspector_action,
          socket.assigns.inspector_path,
          socket.assigns.inspector_staged
        )
  end

  defp parent_path(path), do: path |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")

  defp fleet_lane(agent, approvals),
    do: if(approvals[agent.id], do: "attention", else: agent.status)

  defp title(c), do: c["title"] || "Untitled conversation"

  defp selected_title(agent, cid) do
    case Enum.find(Fleet.conversations(agent), &(&1["id"] == cid)) do
      nil -> "New conversation"
      c -> title(c)
    end
  end

  embed_templates "fleet_live/*"
end
