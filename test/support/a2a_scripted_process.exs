# Actual ACP ScriptedAgent behind an OS stdio boundary. Synthetic test state only.
[script_path, journal] = System.argv()

opts =
  script_path
  |> File.read!()
  |> Jason.decode!()
  |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)

{:ok, agent} = Managoat.ACP.Testing.ScriptedAgent.start_link(Keyword.put(opts, :observer, self()))
:ok = Managoat.ACP.Testing.ScriptedAgent.connect(agent, self())
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
      :ok = Managoat.ACP.Testing.ScriptedAgent.writer(agent).(line)
      loop.(loop)

    {:"$gen_cast", {:stdout, data}} ->
      IO.binwrite(:stdio, data)
      loop.(loop)

    {:scripted_agent, :wrote, frame} ->
      File.write!(journal, Jason.encode!(frame) <> "\n", [:append])
      loop.(loop)

    :eof ->
      System.halt(0)

    _ ->
      loop.(loop)
  end
end

loop.(loop)
