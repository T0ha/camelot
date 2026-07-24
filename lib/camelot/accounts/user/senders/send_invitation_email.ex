defmodule Camelot.Accounts.User.Senders.SendInvitationEmail do
  @moduledoc """
  Sends a marketing-style invitation email to a newly admin-created
  user via Swoosh. In dev mode, viewable at /dev/mailbox.

  Unlike `Camelot.Accounts.User.Senders.SendMagicLink`, this carries
  no token: it just points the user at the sign-in page so they can
  request their own magic link whenever they're ready to start.
  """

  import Swoosh.Email

  alias Camelot.Mailer.Layout

  @spec deliver(Ash.Resource.record()) :: :ok
  def deliver(user) do
    email = to_string(user.email)

    email
    |> build_email(sign_in_url())
    |> Camelot.Mailer.deliver!()

    :ok
  end

  defp sign_in_url do
    query =
      URI.encode_query(
        utm_source: "email",
        utm_medium: "invitation",
        utm_campaign: "admin_invite"
      )

    CamelotWeb.Endpoint.url() <> "/sign-in?" <> query
  end

  defp build_email(to, url) do
    new()
    |> from(Camelot.Mailer.from())
    |> to(to)
    |> subject("You're invited to Camelot AI")
    |> html_body(html_body(url))
    |> text_body(text_body(url))
  end

  defp html_body(url) do
    Layout.html("""
    <h2 style="margin-top: 0;">Your Camelot AI account is ready</h2>
    <p>
      Delegate coding tasks to AI agents and manage them from a kanban
      board. Create tasks, let agents plan and implement them, then
      review and approve before anything ships.
    </p>
    <ul style="padding-left: 20px; line-height: 1.6;">
      <li><strong>Kanban board</strong> — track every task from todo to done.</li>
      <li><strong>Multi-agent coordination</strong> — run agents in parallel across projects.</li>
      <li><strong>Human-in-the-loop</strong> — approve plans before anything is written.</li>
      <li><strong>GitHub-native</strong> — syncs issues, tracks PRs, auto-completes on merge.</li>
    </ul>
    #{Layout.button(url, "Sign in to Camelot AI")}
    #{Layout.fallback_link(url)}
    """)
  end

  defp text_body(url) do
    """
    Your Camelot AI account is ready

    Delegate coding tasks to AI agents and manage them from a kanban
    board. Create tasks, let agents plan and implement them, then
    review and approve before anything ships.

    - Kanban board — track every task from todo to done.
    - Multi-agent coordination — run agents in parallel across projects.
    - Human-in-the-loop — approve plans before anything is written.
    - GitHub-native — syncs issues, tracks PRs, auto-completes on merge.

    Sign in to Camelot AI:
    #{url}
    """
  end
end
