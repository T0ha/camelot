defmodule Camelot.Github.IssueDirectives do
  @moduledoc """
  Reads the per-issue directive labels of the GitHub issue workflow:

    * `camelot:agent:<slug>` — run the task with that Agent CLI.
    * `camelot:model:<id>` — pin the task's `next_model`.
    * `camelot:skip-plan` — take the issue body as the plan and start
      in execution.

  Pure string parsing, no I/O. Whether a label counts at all (who
  applied it, whether the base `camelot` label is present) is decided
  by the caller — see `Camelot.Projects.Changes.SyncGithubIssues` and
  `Camelot.Github.IssueTrust`. See `docs/github-issues-workflow.md`.
  """

  @agent_prefix "camelot:agent:"
  @model_prefix "camelot:model:"
  @skip_plan "camelot:skip-plan"

  @typedoc "The directives an issue's labels carry."
  @type t :: %{
          agent_slug: String.t() | nil,
          model: String.t() | nil,
          skip_planning?: boolean()
        }

  @typedoc "A label as GitHub sends it, or just its name."
  @type label :: String.t() | %{required(String.t()) => String.t()}

  @doc """
  Parses `labels` into directives. When several labels of one kind are
  present, the alphabetically-first value wins, so the result does not
  depend on the order GitHub lists them in.
  """
  @spec parse([label()]) :: t()
  def parse(labels) do
    names = labels |> label_names() |> Enum.sort()

    %{
      agent_slug: first_value(names, @agent_prefix),
      model: first_value(names, @model_prefix),
      skip_planning?: @skip_plan in names
    }
  end

  @doc "True for a per-issue directive label (agent, model, skip-plan)."
  @spec directive?(String.t()) :: boolean()
  def directive?(@skip_plan), do: true
  def directive?(@agent_prefix <> _slug), do: true
  def directive?(@model_prefix <> _model), do: true
  def directive?(_label), do: false

  @doc "Normalises GitHub label maps and plain names to names."
  @spec label_names([label()]) :: [String.t()]
  def label_names(labels), do: Enum.map(labels, &label_name/1)

  defp label_name(%{"name" => name}), do: name
  defp label_name(name), do: name

  defp first_value(names, prefix) do
    Enum.find_value(names, fn name ->
      name
      |> strip_prefix(prefix)
      |> blank_to_nil()
    end)
  end

  defp strip_prefix(name, prefix) do
    case String.split_at(name, String.length(prefix)) do
      {^prefix, value} -> String.trim(value)
      _other -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
