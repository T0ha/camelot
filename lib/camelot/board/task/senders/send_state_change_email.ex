defmodule Camelot.Board.Task.Senders.SendStateChangeEmail do
  @moduledoc """
  Sends a task-state-change email to a task's creator via Swoosh.
  In dev mode, viewable at /dev/mailbox.
  """
  import Swoosh.Email

  @subjects %{
    waiting_for_input: "needs your input",
    error: "hit an error",
    done: "is done"
  }

  @messages %{
    waiting_for_input: "needs your input to continue.",
    error: "hit an error and needs your attention.",
    done: "is done."
  }

  @spec send(Ash.Resource.record(), atom()) :: :ok
  def send(task, kind) do
    new()
    |> from(Camelot.Mailer.from())
    |> to(to_string(task.creator.email))
    |> subject("Task \"#{task.title}\" #{@subjects[kind]}")
    |> html_body(build_html_body(task, kind))
    |> text_body(build_text_body(task, kind))
    |> Camelot.Mailer.deliver!()

    :ok
  end

  defp task_url(task), do: CamelotWeb.Endpoint.url() <> "/tasks/#{task.id}"

  defp build_html_body(task, kind) do
    """
    <h2>Task "#{task.title}" #{@messages[kind]}</h2>
    <p><a href="#{task_url(task)}">View task</a></p>
    """
  end

  defp build_text_body(task, kind) do
    """
    Task "#{task.title}" #{@messages[kind]}

    View task: #{task_url(task)}
    """
  end
end
