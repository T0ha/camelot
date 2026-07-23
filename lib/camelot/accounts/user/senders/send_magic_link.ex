defmodule Camelot.Accounts.User.Senders.SendMagicLink do
  @moduledoc """
  Sends a magic link sign-in email via Swoosh.
  In dev mode, viewable at /dev/mailbox.

  When `:registration_enabled` is `false`, requests for unknown
  identities (binary email, not a loaded `User` struct) are silently
  dropped — no email is sent. Existing users always receive sign-in
  links so they can log in.

  This is the canonical invite-only gate. It catches both the LiveView
  `phx-submit` path (which never hits HTTP) and the HTTP POST path.
  """
  use AshAuthentication.Sender

  import Swoosh.Email

  alias Camelot.Mailer.Layout

  require Logger

  @impl true
  @spec send(
          Ash.Resource.record() | String.t(),
          String.t(),
          keyword()
        ) :: :ok
  def send(user_or_email, token, opts) do
    if blocked_registration?(user_or_email) do
      Logger.info(fn ->
        "Skipped magic link to #{user_or_email}: registration disabled"
      end)

      :ok
    else
      deliver(user_or_email, token, opts)
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

  defp magic_link_url(token) do
    CamelotWeb.Endpoint.url() <> "/magic_link/" <> token
  end

  defp build_email(to, url) do
    new()
    |> from(Camelot.Mailer.from())
    |> to(to)
    |> subject("Your sign-in link for Camelot")
    |> html_body(
      Layout.html("""
      <h2 style="margin-top: 0;">Sign in to Camelot</h2>
      <p>Click the button below to sign in:</p>
      #{Layout.button(url, "Sign in to Camelot")}
      #{Layout.fallback_link(url)}
      <p>This link expires in 10 minutes.</p>
      <p>If you didn't request this, you can safely ignore this email.</p>
      """)
    )
    |> text_body("""
    Sign in to Camelot

    Visit this link to sign in:
    #{url}

    This link expires in 10 minutes.
    If you didn't request this, you can safely ignore this email.
    """)
  end
end
