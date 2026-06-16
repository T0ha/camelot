defmodule CamelotWeb.PromptTemplateLiveTest do
  use CamelotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Camelot.Accounts.User
  alias Camelot.Projects.Project
  alias Camelot.Prompts.PromptTemplate

  describe "as a non-admin user" do
    setup :register_and_log_in_user

    setup %{user: user} do
      {:ok, project} =
        Ash.create(
          Project,
          %{name: "prompt-proj-#{System.unique_integer()}", path: "/tmp/p"},
          actor: user
        )

      other =
        Ash.Seed.seed!(User, %{email: "other-prompt-#{System.unique_integer()}@x.com"})

      # System global — visible
      {:ok, system_global} =
        Ash.create(PromptTemplate, %{
          slug: "sg-#{System.unique_integer()}",
          name: "System Global",
          body: "system body"
        })

      # User-global for self — visible/writable
      {:ok, own_user} =
        Ash.create(PromptTemplate, %{
          slug: "ug-#{System.unique_integer()}",
          name: "Own User Global",
          body: "own user body",
          user_id: user.id
        })

      # User-global for someone else — NOT visible
      {:ok, other_user} =
        Ash.create(PromptTemplate, %{
          slug: "ou-#{System.unique_integer()}",
          name: "OtherUserGlobal",
          body: "other user body",
          user_id: other.id
        })

      # Project-scoped in user's project — visible/writable
      {:ok, own_project} =
        Ash.create(PromptTemplate, %{
          slug: "op-#{System.unique_integer()}",
          name: "Own Project",
          body: "own project body",
          project_id: project.id
        })

      %{
        system_global: system_global,
        own_user: own_user,
        other_user: other_user,
        own_project: own_project
      }
    end

    test "lists system, own-user, and own-project prompts but not other-user-global",
         %{conn: conn, system_global: sg, own_user: ou, other_user: other_user, own_project: op} do
      {:ok, _view, html} = live(conn, ~p"/prompts")

      assert html =~ sg.name
      assert html =~ ou.name
      assert html =~ op.name
      refute html =~ other_user.name
    end

    test "cannot edit a system global", %{conn: conn, system_global: sg} do
      assert {:error, {kind, %{to: "/prompts"}}} =
               live(conn, ~p"/prompts/#{sg.id}/edit")

      assert kind in [:redirect, :live_redirect]
    end

    test "can edit own user-global", %{conn: conn, own_user: ou} do
      {:ok, _view, html} = live(conn, ~p"/prompts/#{ou.id}/edit")
      assert html =~ "Edit Template"
    end

    test "create defaults to user-global", %{conn: conn, user: user} do
      require Ash.Query

      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      slug = "fresh-#{System.unique_integer()}"

      view
      |> form("#template-form", %{
        "scope" => "user",
        "slug" => slug,
        "name" => "Fresh",
        "body" => "fresh body",
        "description" => ""
      })
      |> render_submit()

      assert [%PromptTemplate{user_id: uid, project_id: nil}] =
               PromptTemplate
               |> Ash.Query.filter(slug == ^slug)
               |> Ash.read!()

      assert uid == user.id
    end
  end

  describe "as an admin" do
    setup :register_and_log_in_admin

    test "with Showing: All sees prompts owned by others", %{conn: conn} do
      other = Ash.Seed.seed!(User, %{email: "ax-#{System.unique_integer()}@x.com"})

      {:ok, theirs} =
        Ash.create(PromptTemplate, %{
          slug: "ax-#{System.unique_integer()}",
          name: "AdminCanSeeThis",
          body: "body",
          user_id: other.id
        })

      {:ok, _view, html} = live(conn, ~p"/prompts?scope=all")
      assert html =~ theirs.name
    end

    test "can edit any prompt", %{conn: conn} do
      other = Ash.Seed.seed!(User, %{email: "ay-#{System.unique_integer()}@x.com"})

      {:ok, theirs} =
        Ash.create(PromptTemplate, %{
          slug: "ay-#{System.unique_integer()}",
          name: "Theirs",
          body: "body",
          user_id: other.id
        })

      {:ok, _view, html} = live(conn, ~p"/prompts/#{theirs.id}/edit")
      assert html =~ "Edit Template"
    end
  end
end
