defmodule Mix.Tasks.Assets.Build do
  use Mix.Task

  @shortdoc "Copy the pinned Phoenix browser clients into the desktop release"
  def run(_) do
    Mix.Task.run("deps.loadpaths")
    target = "priv/static/assets"
    File.mkdir_p!(target)

    for {app, name} <- [{:phoenix, "phoenix"}, {:phoenix_live_view, "phoenix_live_view"}] do
      source = Path.join([Mix.Project.deps_path(), Atom.to_string(app), "priv/static/#{name}.js"])
      File.cp!(source, Path.join(target, name <> ".js"))
    end
  end
end
