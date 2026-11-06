defmodule CamelotWeb.ProfileLive.ApiKeysTest do
  use CamelotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Camelot.Accounts.Credential

  require Ash.Query

  @kinds [:claude_api_key, :openai_api_key, :kimi_api_key, :generic]

  setup :register_and_log_in_user

  test "renders its own heading and page title", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile/api-keys")

    assert has_element?(view, "h1", "API keys")
    assert page_title(view) =~ "API keys"
  end

  test "ignores unrelated messages without crashing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile/api-keys")

    send(view.pid, {:some_unexpected_message, :payload})

    assert render(view) =~ "API keys"
  end

  test "renders one row per non-SSH kind and no kind select", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/profile/api-keys")

    for kind <- @kinds do
      assert has_element?(view, "#api-key-row-#{kind}")
      assert has_element?(view, "#api-key-form-#{kind}")
    end

    refute has_element?(view, "#api-key-row-ssh_private_key")
    refute has_element?(view, "select")
    refute html =~ "Kind"
    assert html =~ "Claude API key — Claude Code"
    assert html =~ "OpenAI API key — Codex"
    assert html =~ "Kimi API key — Kimi Code"
  end

  test "the Kimi row explains that either key source works", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile/api-keys")

    assert has_element?(view, "#api-key-hint-kimi_api_key", "Kimi Open Platform key")
    refute has_element?(view, "#api-key-hint-claude_api_key")
  end

  test "rows start as not set with a Save button and no Remove", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile/api-keys")

    assert has_element?(view, "#api-key-row-claude_api_key", "Not set")
    assert has_element?(view, "#api-key-form-claude_api_key button", "Save")
    refute has_element?(view, "#api-key-row-claude_api_key button", "Remove")
  end

  test "saving creates a key and shows it as set", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/profile/api-keys")

    html = save_key(view, "claude_api_key", "sk-one")

    assert html =~ "API key saved"
    assert [%{value: "sk-one", name: nil}] = credentials_for(user.id, :claude_api_key)
    assert has_element?(view, "#api-key-row-claude_api_key", "Set")
    assert has_element?(view, "#api-key-form-claude_api_key button", "Replace")
    assert has_element?(view, "#api-key-row-claude_api_key button", "Remove")
  end

  test "saving again updates the same row and clears the usage limit",
       %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/profile/api-keys")
    save_key(view, "claude_api_key", "sk-one")

    [cred] = credentials_for(user.id, :claude_api_key)

    {:ok, _} =
      Ash.update(
        cred,
        %{
          usage_limited_until: DateTime.add(DateTime.utc_now(), 3600),
          usage_limit_window: "5h"
        },
        action: :mark_usage_limited
      )

    {:ok, view, html} = live(conn, ~p"/profile/api-keys")
    assert html =~ "Usage-limited until"

    save_key(view, "claude_api_key", "sk-two")

    assert [updated] = credentials_for(user.id, :claude_api_key)
    assert updated.id == cred.id
    assert updated.value == "sk-two"
    assert is_nil(updated.usage_limited_until)
    refute render(view) =~ "Usage-limited until"
  end

  test "Remove deletes the key", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/profile/api-keys")
    save_key(view, "openai_api_key", "sk-openai")
    assert [_] = credentials_for(user.id, :openai_api_key)

    html =
      view
      |> element("#api-key-row-openai_api_key button", "Remove")
      |> render_click()

    assert html =~ "API key removed"
    assert credentials_for(user.id, :openai_api_key) == []
    assert has_element?(view, "#api-key-row-openai_api_key", "Not set")
  end

  test "Remove clears every legacy key of that kind", %{conn: conn, user: user} do
    for name <- ["a", "b"] do
      {:ok, _} =
        Ash.create(Credential, %{
          user_id: user.id,
          kind: :generic,
          name: name,
          value: "v-#{name}"
        })
    end

    {:ok, view, _html} = live(conn, ~p"/profile/api-keys")

    view |> element("#api-key-row-generic button", "Remove") |> render_click()

    assert credentials_for(user.id, :generic) == []
  end

  test "an unknown kind gets an error flash and creates nothing",
       %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/profile/api-keys")

    html = render_hook(view, "save_api_key", %{"kind" => "bogus", "value" => "x"})
    assert html =~ "Unknown API key type"

    html =
      render_hook(view, "save_api_key", %{
        "kind" => "ssh_private_key",
        "value" => "x"
      })

    assert html =~ "Unknown API key type"

    assert Credential
           |> Ash.Query.filter(user_id == ^user.id)
           |> Ash.read!() == []
  end

  test "an unknown kind cannot be removed either", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile/api-keys")

    assert render_hook(view, "delete_api_key", %{"kind" => "bogus"}) =~
             "Unknown API key type"
  end

  defp save_key(view, kind, value) do
    view
    |> form("#api-key-form-#{kind}", %{"value" => value})
    |> render_submit()
  end

  defp credentials_for(user_id, kind) do
    Credential
    |> Ash.Query.filter(user_id == ^user_id and kind == ^kind)
    |> Ash.Query.load(:value)
    |> Ash.read!()
  end
end
