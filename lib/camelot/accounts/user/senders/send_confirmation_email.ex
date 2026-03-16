defmodule Camelot.Accounts.User.Senders.SendConfirmationEmail do
  @moduledoc """
  Sends an email confirmation via Swoosh.
  In dev mode, viewable at /dev/mailbox.
  """
  use AshAuthentication.Sender

  import Swoosh.Email

  @impl true
  @spec send(
          Ash.Resource.record(),
          String.t(),
          keyword()
        ) :: :ok
  def send(user, token, _opts) do
    email = to_string(user.email)
    url = confirmation_url(token)

    email
    |> build_email(url)
    |> Camelot.Mailer.deliver!()

    :ok
  end

  defp confirmation_url(token) do
    CamelotWeb.Endpoint.url() <>
      "/auth/user/confirm_new_user?confirm=" <>
      token
  end

  defp build_email(to, url) do
    new()
    |> from({"Camelot", "noreply@camelot.dev"})
    |> to(to)
    |> subject("Confirm your email for Camelot")
    |> html_body("""
    <h2>Confirm your email</h2>
    <p>Click the link below to confirm:</p>
    <p><a href="#{url}">Confirm email</a></p>
    """)
    |> text_body("""
    Confirm your email

    Visit this link to confirm:
    #{url}
    """)
  end
end
