defmodule Camelot.Mailer.Layout do
  @moduledoc """
  Shared branded HTML shell for all system emails: dark header with
  the "Camelot AI" wordmark, white card body, purple CTA button, and
  a gray fallback-link footer.
  """

  @spec html(String.t()) :: String.t()
  def html(inner_content) do
    """
    <style>
      @import url('https://fonts.googleapis.com/css2?family=MedievalSharp&display=swap');
    </style>
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
          #{inner_content}
        </div>
      </div>
    </div>
    """
  end

  @spec button(String.t(), String.t()) :: String.t()
  def button(url, label) do
    """
    <p style="text-align: center; margin: 32px 0;">
      <a href="#{url}" style="background: #7c3aed; color: #ffffff; \
    padding: 12px 24px; border-radius: 6px; text-decoration: none; \
    font-weight: bold; display: inline-block;">
        #{label}
      </a>
    </p>
    """
  end

  @spec fallback_link(String.t()) :: String.t()
  def fallback_link(url) do
    """
    <p style="color: #666666; font-size: 14px;">
      If the button doesn't work, copy and paste this link into your browser:<br>
      <a href="#{url}" style="color: #7c3aed;">#{url}</a>
    </p>
    """
  end
end
