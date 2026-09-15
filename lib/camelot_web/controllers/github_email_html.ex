defmodule CamelotWeb.GithubEmailHTML do
  @moduledoc """
  Renders the "your GitHub email changed" prompt.

  See the `github_email_html` directory for all templates
  available.
  """
  use CamelotWeb, :html

  embed_templates "github_email_html/*"
end
