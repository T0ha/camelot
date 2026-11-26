defmodule Camelot.Accounts.User.Senders.SendMagicLink do
  @moduledoc """
  Sends a magic link sign-in email via Swoosh.
  In dev mode, viewable at /dev/mailbox.

  When `:registration_enabled` is `false`, requests for unknown
  identities (binary email, not a loaded `User` struct) are silently
  dropped — no email is sent. Existing users always receive sign-in
  links so they can log in.

  When `:magic_link_enabled` is `false`, nothing is sent at all.

  This is the canonical invite-only gate. It catches both the LiveView
  `phx-submit` path (which never hits HTTP) and the HTTP POST path.
  """
  use AshAuthentication.Sender

  import Swoosh.Email

  alias Camelot.Accounts.MagicLink
  alias Camelot.Mailer.Layout

  require Logger

  @impl true
  @spec send(
          Ash.Resource.record() | String.t(),
          String.t(),
          keyword()
        ) :: :ok
  def send(user_or_email, token, opts) do
    case skip_reason(user_or_email) do
      nil ->
        deliver(user_or_email, token, opts)

      reason ->
        Logger.info(fn -> "Skipped magic link: #{reason}" end)
        :ok
    end
  end

  defp skip_reason(identity) do
    if MagicLink.enabled?() do
      registration_skip_reason(identity)
    else
      "magic link sign-in disabled"
    end
  end

  defp registration_skip_reason(identity) do
    if blocked_registration?(identity) do
      "registration disabled"
    end
  end

  defp blocked_registration?(identity) when is_binary(identity),
    do: not Application.get_env(:camelot, :registration_enabled, true)

  defp blocked_registration?(_user_struct), do: false

  defp deliver(user_or_email, token, _opts) do
    email = extract_email(user_or_email)
    url = magic_link_url(token)

    email
    |> build_email(url)
    |> Camelot.Mailer.deliver!()

    :ok
  end

  defp extract_email(%{email: email}), do: to_string(email)
  defp extract_email(email) when is_binary(email), do: email

  # Points straight at the strategy's GET sign-in endpoint so opening
  # the link signs the user in, with no interstitial "Sign In" page.
  defp magic_link_url(token) do
    CamelotWeb.Endpoint.url() <>
      "/auth/user/magic_link?" <> URI.encode_query(token: token)
  end

  defp build_email(to, url) do
    new()
    |> from(Camelot.Mailer.from())
    |> to(to)
    |> subject("Your sign-in link for 🏰 Camelot AI")
    |> html_body(
      Layout.html("""
      <h2 style="margin-top: 0;">Sign in to 🏰 Camelot AI</h2>
      <p>Click the button below to sign in:</p>
      #{Layout.button(url, "Sign in to 🏰 Camelot AI")}
      #{Layout.fallback_link(url)}
      <p>This link expires in 10 minutes.</p>
      <p>If you didn't request this, you can safely ignore this email.</p>
      """)
    )
    |> text_body("""
    Sign in to 🏰 Camelot AI

    Visit this link to sign in:
    #{url}

    This link expires in 10 minutes.
    If you didn't request this, you can safely ignore this email.
    """)
  end
end
