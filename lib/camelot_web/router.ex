defmodule CamelotWeb.Router do
  use CamelotWeb, :router
  use AshAuthentication.Phoenix.Router

  alias AshAuthentication.Phoenix.Overrides.Default
  alias Camelot.Accounts.User

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CamelotWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :load_from_bearer
  end

  scope "/" do
    pipe_through :browser

    sign_in_route(
      auth_routes_prefix: "/auth",
      overrides: [
        CamelotWeb.AuthOverrides,
        Default
      ]
    )

    sign_out_route(CamelotWeb.AuthController)

    magic_sign_in_route(
      User,
      :magic_link,
      auth_routes_prefix: "/auth",
      overrides: [
        CamelotWeb.AuthOverrides,
        Default
      ]
    )

    auth_routes(
      CamelotWeb.AuthController,
      User,
      path: "/auth"
    )
  end

  ash_authentication_live_session :authenticated,
    otp_app: :camelot,
    on_mount: {
      CamelotWeb.LiveUserAuth,
      :live_user_required
    } do
    scope "/", CamelotWeb do
      pipe_through :browser

      live "/", BoardLive
      live "/tasks/:id", TaskLive

      live "/projects", ProjectLive.Index, :index
      live "/projects/new", ProjectLive.Index, :new

      live "/projects/:id/edit",
           ProjectLive.Index,
           :edit

      live "/projects/:id", ProjectLive.Show, :show

      live "/agents", AgentLive.Index, :index
      live "/agents/new", AgentLive.Index, :new
      live "/agents/:id", AgentLive.Show

      live "/prompts", PromptTemplateLive, :index
      live "/prompts/new", PromptTemplateLive, :new
      live "/prompts/:id/edit", PromptTemplateLive, :edit
    end
  end

  ash_authentication_live_session :maybe_authenticated,
    otp_app: :camelot,
    on_mount: {
      CamelotWeb.LiveUserAuth,
      :live_user_optional
    } do
    scope "/", CamelotWeb do
      pipe_through :browser
    end
  end

  if Application.compile_env(:camelot, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard",
        metrics: CamelotWeb.Telemetry

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
