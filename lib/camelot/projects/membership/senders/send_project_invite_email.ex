defmodule Camelot.Projects.Membership.Senders.SendProjectInviteEmail do
  @moduledoc """
  Sends a "you've been added to a project" email to a project
  invitee via Swoosh. In dev mode, viewable at /dev/mailbox.
  """

  import Swoosh.Email

  @spec deliver(Ash.Resource.record(), Ash.Resource.record()) :: :ok
  def deliver(user, project) do
    email = to_string(user.email)
    url = project_url(project)

    email
    |> build_email(project, url)
    |> Camelot.Mailer.deliver!()

    :ok
  end

  defp project_url(project) do
    CamelotWeb.Endpoint.url() <> "/projects/#{project.id}"
  end

  defp build_email(to, project, url) do
    new()
    |> from(Camelot.Mailer.from())
    |> to(to)
    |> subject("You've been added to #{project.name} on Camelot AI")
    |> html_body(render_html_body(project, url))
    |> text_body(render_text_body(project, url))
  end

  defp render_html_body(project, url) do
    """
    <div style="background: #f5f5f5; padding: 24px;">
      <div style="font-family: -apple-system, Helvetica, Arial, sans-serif; \
    max-width: 560px; margin: 0 auto; color: #1a1a2e; background: #ffffff; \
    border-radius: 0.75rem; overflow: hidden; \
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);">
        <div style="background: #1a1a2e; padding: 32px 24px; text-align: center;">
          <h1 style="font-family: 'MedievalSharp', cursive; font-weight: 900; \
    letter-spacing: 0.025em; color: #ffffff; font-size: 24px; margin: 0;">
            Camelot AI
          </h1>
        </div>
        <div style="padding: 32px 24px;">
          <h2 style="margin-top: 0;">You've been added to #{project.name}</h2>
          <p>
            You can now collaborate on this project's tasks and agents.
          </p>
          <p style="text-align: center; margin: 32px 0;">
            <a href="#{url}" style="background: #7c3aed; color: #ffffff; \
    padding: 12px 24px; border-radius: 6px; text-decoration: none; \
    font-weight: bold; display: inline-block;">
              Open #{project.name}
            </a>
          </p>
          <p style="color: #666666; font-size: 14px;">
            If the button doesn't work, copy and paste this link into your browser:<br>
            <a href="#{url}" style="color: #7c3aed;">#{url}</a>
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp render_text_body(project, url) do
    """
    You've been added to #{project.name}

    You can now collaborate on this project's tasks and agents.

    Open #{project.name}:
    #{url}
    """
  end
end
