defmodule Camelot.Github.IssueDirectivesTest do
  use ExUnit.Case, async: true

  alias Camelot.Github.IssueDirectives

  describe "parse/1" do
    test "no directive labels yields the defaults" do
      assert IssueDirectives.parse(["camelot", "bug"]) == %{
               agent_slug: nil,
               model: nil,
               skip_planning?: false
             }
    end

    test "an empty label list yields the defaults" do
      assert IssueDirectives.parse([]) == %{
               agent_slug: nil,
               model: nil,
               skip_planning?: false
             }
    end

    test "reads the agent slug, model id and skip-plan flag" do
      labels = [
        "camelot",
        "camelot:agent:claude_code",
        "camelot:model:claude-opus-5-5",
        "camelot:skip-plan"
      ]

      assert IssueDirectives.parse(labels) == %{
               agent_slug: "claude_code",
               model: "claude-opus-5-5",
               skip_planning?: true
             }
    end

    test "keeps colons inside a model id" do
      labels = ["camelot:model:us.anthropic.claude:v1"]

      assert %{model: "us.anthropic.claude:v1"} = IssueDirectives.parse(labels)
    end

    test "trims surrounding whitespace from the value" do
      assert %{agent_slug: "codex"} = IssueDirectives.parse(["camelot:agent: codex "])
    end

    test "a directive label with an empty value is ignored" do
      assert %{agent_slug: nil, model: nil} =
               IssueDirectives.parse(["camelot:agent:", "camelot:model:  "])
    end

    test "with several agent labels the first one (alphabetically) wins" do
      labels = ["camelot:agent:zeta", "camelot:agent:alpha"]

      assert %{agent_slug: "alpha"} = IssueDirectives.parse(labels)
    end

    test "unrelated and malformed labels are ignored" do
      labels = ["camelot:agentclaude", "camelot-skip-plan", "agent:codex", "camelot:unknown:x"]

      assert IssueDirectives.parse(labels) == %{
               agent_slug: nil,
               model: nil,
               skip_planning?: false
             }
    end

    test "directives are read even without the base camelot label" do
      # Whether the issue is attached at all is the caller's decision.
      assert %{skip_planning?: true} = IssueDirectives.parse(["camelot:skip-plan"])
    end

    test "accepts GitHub label maps as well as names" do
      labels = [%{"name" => "camelot:agent:codex"}, %{"name" => "camelot:skip-plan"}]

      assert %{agent_slug: "codex", skip_planning?: true} = IssueDirectives.parse(labels)
    end
  end

  describe "directive?/1" do
    test "is true only for the per-issue directive labels" do
      assert IssueDirectives.directive?("camelot:agent:codex")
      assert IssueDirectives.directive?("camelot:model:gpt-5")
      assert IssueDirectives.directive?("camelot:skip-plan")
      refute IssueDirectives.directive?("camelot")
      refute IssueDirectives.directive?("camelot:done")
      refute IssueDirectives.directive?("bug")
    end
  end

  describe "label_names/1" do
    test "normalises GitHub label maps and plain names" do
      assert IssueDirectives.label_names([%{"name" => "a"}, "b"]) == ["a", "b"]
    end
  end
end
