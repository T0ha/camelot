defmodule Camelot.Accounts.User.Senders.SendMagicLink do
  @moduledoc """
  Sends a magic link sign-in email via Swoosh.
  In dev mode, viewable at /dev/mailbox.
  """
  use AshAuthentication.Sender

  import Swoosh.Email

  @impl true
  @spec send(
          Ash.Resource.record() | String.t(),
          String.t(),
          keyword()
        ) :: :ok
  def send(user_or_email, token, _opts) do
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
    |> from({"Camelot", "noreply@camelot.dev"})
    |> to(to)
    |> subject("Your sign-in link for Camelot")
    |> html_body("""
    <h2>Sign in to Camelot</h2>
    <p>Click the link below to sign in:</p>
    <p><a href="#{url}">Sign in to Camelot</a></p>
    <p>This link expires in 10 minutes.</p>
    <p>If you didn't request this, you can safely ignore this email.</p>
    """)
    |> text_body("""
    Sign in to Camelot

    Visit this link to sign in:
    #{url}

    This link expires in 10 minutes.
    If you didn't request this, you can safely ignore this email.
    """)
  end
end
