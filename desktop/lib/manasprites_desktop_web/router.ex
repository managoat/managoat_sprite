defmodule ManaspritesDesktopWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ManaspritesDesktopWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :authenticated do
    plug ManaspritesDesktopWeb.LocalAuth
  end

  scope "/", ManaspritesDesktopWeb do
    pipe_through :browser
    get "/launch", LaunchController, :show
  end

  scope "/", ManaspritesDesktopWeb do
    pipe_through [:browser, :authenticated]

    live_session :local, on_mount: [{ManaspritesDesktopWeb.LocalAuth, :default}] do
      live "/", FleetLive
    end
  end
end
