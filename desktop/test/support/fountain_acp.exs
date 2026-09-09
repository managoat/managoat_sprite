# Real ScriptedAgent over OS stdio, executing only the suite's bounded file task
# in a synthetic workspace. This proves the host/service wire, not model quality.
[workspace] = System.argv()
alias Managoat.ACP.Testing.ScriptedAgent

{:ok, agent} =
  ScriptedAgent.start_link(capabilities: %{"sessionCapabilities" => %{"resume" => %{}}})

:ok = ScriptedAgent.connect(agent, self())
parent = self()

spawn_link(fn ->
  Stream.repeatedly(fn -> IO.read(:stdio, :line) end)
  |> Enum.reduce_while(nil, fn
    :eof, _ ->
      send(parent, :eof)
      {:halt, nil}

    {:error, _}, _ ->
      send(parent, :eof)
      {:halt, nil}

    line, _ ->
      send(parent, {:line, line})
      {:cont, nil}
  end)
end)

loop = fn loop ->
  receive do
    {:line, line} ->
      case Jason.decode!(line) do
        %{"method" => "session/prompt", "params" => %{"prompt" => prompt}} ->
          text = Enum.map_join(prompt, "", &(&1["text"] || ""))

          ScriptedAgent.update(agent, %{
            "sessionUpdate" => "agent_message_chunk",
            "content" => %{"type" => "text", "text" => "Starting the file task.\n"}
          })

          Task.start(fn ->
            [file] = Regex.run(~r/fountain-suite-[a-z0-9-]+\.txt/, text)

            result =
              if String.contains?(text, "write exactly") do
                [_, nonce] = Regex.run(~r/text ([a-f0-9-]{36}) followed/, text)

                System.cmd(
                  "sh",
                  [
                    "-c",
                    "sleep 2; printf '%s\\n' \"$1\" > \"$2\"; cat \"$2\"",
                    "fixture",
                    nonce,
                    file
                  ],
                  cd: workspace
                )
              else
                System.cmd("sh", ["-c", "sleep 2; cat \"$1\"", "fixture", file], cd: workspace)
              end

            send(parent, {:tool_done, line, result})
          end)

        _ ->
          :ok = ScriptedAgent.writer(agent).(line)
      end

      loop.(loop)

    {:tool_done, line, {text, 0}} ->
      ScriptedAgent.update(agent, %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "shell",
        "title" => "sh",
        "kind" => "execute",
        "status" => "completed"
      })

      ScriptedAgent.update(agent, %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => text}
      })

      :ok = ScriptedAgent.writer(agent).(line)
      loop.(loop)

    {:"$gen_cast", {:stdout, bytes}} ->
      IO.binwrite(:stdio, bytes)
      loop.(loop)

    :eof ->
      System.halt(0)

    _ ->
      loop.(loop)
  end
end

loop.(loop)
