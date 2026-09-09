defmodule Managoat.Sprite.ConversationServer do
  @moduledoc "Runs one accepted turn and persists every protocol report before exposing it."
  use GenServer, restart: :temporary
  alias Managoat.Sprite.{Config, Store, Engine, Lifecycle}
  alias Managoat.ACP.Peer
  def start_link(turn), do: GenServer.start_link(__MODULE__, turn)
  @impl true
  def init(turn) do
    {:ok,
     %{
       turn: turn,
       peer: nil,
       command: nil,
       peer_ref: nil,
       hold: "managoat-" <> Store.call(:identity) <> "-" <> turn["id"],
       renew_at: nil,
       bytes: 0,
       wire_bytes: 0,
       cancelled: turn["cancel_requested"] == true,
       failure: nil
     }, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, %{cancelled: true} = s),
    do: finish(s, "interrupted", "explicit_cancel", nil)

  def handle_continue(:start, s) do
    runtime = Engine.runtime()

    with :ok <- Store.call({:launch, s.turn["id"]}),
         :ok <- Lifecycle.acquire(s.hold),
         {:ok, command} <- runtime.start(self()) do
      :ok = Engine.execution(command)
      c = Store.call({:get, s.turn["conversation_id"]})
      turn = s.turn

      writer = fn data ->
        bytes = IO.iodata_to_binary(data)

        case Jason.decode(bytes) do
          {:ok, %{"method" => "session/prompt", "id" => rid, "params" => %{"sessionId" => sid}}} ->
            with :ok <- Store.call({:session, turn["conversation_id"], sid}),
                 :ok <- Store.call({:dispatch, turn["id"], rid}),
                 do: runtime.write(command, data)

          _ ->
            runtime.write(command, data)
        end
      end

      config = Config.get()
      ref = make_ref()

      {:ok, peer} =
        Peer.start(
          owner: self(),
          writer: writer,
          ref: ref,
          prompt: turn["prompt"],
          mode: if(c["runtime_session_id"], do: :continue, else: :run),
          session_id: c["runtime_session_id"],
          cwd: config["workspace"],
          permission_policy:
            Managoat.ACP.Permissions.effective(config["permissions"], turn["permission_policy"]),
          model: Managoat.Runtimes.Model.acp_model(config["runtime"], turn["requested_model"])
        )

      runtime.connect(command, peer)
      Process.monitor(peer)
      Process.send_after(self(), :renew, 60_000)
      Process.send_after(self(), :timeout, config["turn_timeout_seconds"] * 1000)

      {:noreply,
       %{
         s
         | peer: peer,
           peer_ref: ref,
           command: command,
           renew_at: System.monotonic_time(:millisecond)
       }}
    else
      {:error, {409, reason}} -> finish(s, "failed", reason, nil)
      _ -> finish(s, "failed", "runtime_start_failed", nil)
    end
  end

  @impl true
  def handle_info({:stdout, %{ref: command}, data}, %{command: command} = s) do
    bytes = s.wire_bytes + byte_size(data)

    cond do
      bytes > Config.get()["max_output_bytes"] ->
        finish(s, "failed", "output_budget_exceeded", nil)

      peer_overloaded?(s.peer) ->
        finish(s, "failed", "output_backpressure_exceeded", nil)

      true ->
        Peer.stdout(s.peer, data)
        {:noreply, %{s | wire_bytes: bytes}}
    end
  end

  def handle_info({:stderr, %{ref: command}, data}, %{command: command} = s),
    do: output(s, "stderr", data)

  def handle_info(
        {:error, %{ref: command}, :output_backpressure_exceeded},
        %{command: command} = s
      ),
      do: finish(s, "failed", "output_backpressure_exceeded", nil)

  def handle_info({kind, %{ref: command}, _}, %{command: command} = s)
      when kind in [:exit, :error], do: finish(s, "failed", "runtime_exited", nil)

  def handle_info({:acp, ref, payload}, %{peer_ref: ref} = s), do: report(payload, s)

  def handle_info(:interrupt, s) do
    if s.peer, do: Peer.cancel(s.peer)
    Process.send_after(self(), :force_stop, 10_000)
    {:noreply, %{s | cancelled: true}}
  end

  def handle_info(:timeout, s), do: finish(s, "interrupted", "turn_timeout", nil)

  def handle_info(:force_stop, s),
    do: finish(s, "interrupted", s.failure || "explicit_cancel_forced", nil)

  def handle_info({:answer, rid, option}, s) do
    Peer.answer_permission(s.peer, rid, option)
    {:noreply, s}
  end

  def handle_info({:permission_timeout, rid}, s) do
    case Store.call({:permission, rid}) do
      %{"status" => "pending"} ->
        Store.call({:expire, rid})
        Peer.deny_permission(s.peer, rid)

      _ ->
        :ok
    end

    {:noreply, s}
  end

  def handle_info(:renew, s) do
    case Lifecycle.acquire(s.hold) do
      :ok ->
        Process.send_after(self(), :renew, 60_000)
        {:noreply, %{s | renew_at: System.monotonic_time(:millisecond)}}

      _ ->
        if System.monotonic_time(:millisecond) - s.renew_at > 240_000 do
          finish(s, "interrupted", "sprite_hold_lost", nil)
        else
          Process.send_after(self(), :renew, 10_000)
          {:noreply, s}
        end
    end
  end

  def handle_info({:DOWN, _, :process, peer, _}, %{peer: peer} = s),
    do: finish(s, "failed", "peer_exited", nil)

  def handle_info(_, s), do: {:noreply, s}

  defp report({:session, id}, s) do
    Store.call({:session, s.turn["conversation_id"], id})
    {:noreply, s}
  end

  defp report({:lines, stream, data}, s), do: output(s, stream, data)

  defp report({:permission_ask, rid, tool, options}, s) do
    timeout = Config.get()["permission_timeout_seconds"] * 1000

    Store.call(
      {:ask, s.turn["conversation_id"], s.turn["id"], rid, tool, options,
       System.system_time(:millisecond) + timeout}
    )

    Process.send_after(self(), {:permission_timeout, rid}, timeout)
    {:noreply, s}
  end

  defp report({:model_selected, requested, effective, source}, s) do
    Store.call(
      {:model, s.turn["id"], %{requested: requested, effective: effective, source: source}}
    )

    {:noreply, s}
  end

  defp report({:done, reason, usage}, s) do
    status =
      cond do
        s.failure -> "failed"
        s.cancelled or reason == "cancelled" -> "interrupted"
        reason == "refusal" -> "failed"
        true -> "completed"
      end

    reason =
      cond do
        s.failure -> s.failure
        s.cancelled -> "explicit_cancel"
        status == "completed" -> nil
        true -> reason
      end

    finish(s, status, reason, usage)
  end

  defp report({:failed, _}, %{cancelled: true, failure: nil} = s),
    do: finish(s, "interrupted", "explicit_cancel", nil)

  defp report({:failed, {:acp_error, tag, _}}, s) when tag in [:resume_session, :load_session],
    do: finish(s, "failed", "session_unavailable", nil)

  defp report({:failed, :acp_agent_cannot_resume}, s),
    do: finish(s, "failed", "session_unavailable", nil)

  defp report({:failed, _}, s), do: finish(s, "failed", "acp_failed", nil)
  defp report(_, s), do: {:noreply, s}

  defp peer_overloaded?(peer) do
    case Process.info(peer, :message_queue_len) do
      {:message_queue_len, count} -> count >= 1024
      nil -> false
    end
  end

  defp output(s, stream, data) do
    bytes = s.bytes + byte_size(data)

    if bytes > Config.get()["max_output_bytes"] do
      finish(s, "failed", "output_budget_exceeded", nil)
    else
      Store.call({:output, s.turn["conversation_id"], s.turn["id"], stream, data})

      {:noreply,
       %{s | bytes: bytes, failure: s.failure || Managoat.Sprite.ProviderFailure.reason(data)}}
    end
  end

  defp finish(s, status, reason, usage) do
    if s.peer, do: Peer.close(s.peer)
    result = if s.command, do: Engine.runtime().stop(s.command), else: :ok

    if result in [:ok, {:error, :command_exited}] do
      Store.call({:finish, s.turn["id"], status, reason, usage})
      Lifecycle.release(s.hold)
      {:stop, :normal, s}
    else
      {:stop, :cleanup_failed, s}
    end
  end

  @impl true
  def format_status(status) do
    # OTP crash reports are operational logs, never a copy of a prompt or key.
    Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted})
  end
end
