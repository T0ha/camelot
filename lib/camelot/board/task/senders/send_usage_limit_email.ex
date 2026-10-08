defmodule Camelot.Board.Task.Senders.SendUsageLimitEmail do
  @moduledoc """
  Sends a usage-limit pause/resume email to a user via Swoosh.
  In dev mode, viewable at /dev/mailbox.
  """
  import Swoosh.Email

  alias Camelot.Mailer.Layout

  @subjects %{
    paused: "Your tasks are paused — usage limit reached",
    resumed: "Your tasks have resumed"
  }

  @spec send(Ash.Resource.record(), atom(), String.t() | nil) :: :ok
  def send(user, kind, window) do
    new()
    |> from(Camelot.Mailer.from())
    |> to(to_string(user.email))
    |> subject(@subjects[kind])
    |> html_body(build_html_body(kind, window))
    |> text_body(build_text_body(kind, window))
    |> Camelot.Mailer.deliver!()

    :ok
  end

  defp build_html_body(kind, window) do
    Layout.html("""
    <h2 style="margin-top: 0;">#{@subjects[kind]}</h2>
    <p>#{message(kind, window)}</p>
    """)
  end

  defp build_text_body(kind, window), do: message(kind, window)

  defp message(:paused, nil) do
    "One of your agent CLIs hit its provider's usage limit. Affected " <>
      "tasks are paused and will resume automatically once the limit resets."
  end

  defp message(:paused, window) do
    "One of your agent CLIs hit its #{window} provider usage limit. " <>
      "Affected tasks are paused and will resume automatically once the limit resets."
  end

  defp message(:resumed, _window) do
    "Your previously paused tasks have resumed and are back in the queue."
  end
end
