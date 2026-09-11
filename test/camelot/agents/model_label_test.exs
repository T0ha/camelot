defmodule Camelot.Agents.ModelLabelTest do
  use ExUnit.Case, async: true

  alias Camelot.Agents.ModelLabel

  describe "humanize/1" do
    test "capitalizes each hyphen-separated word" do
      assert ModelLabel.humanize("claude-opus-5") == "Claude Opus 5"
      assert ModelLabel.humanize("claude-sonnet-5") == "Claude Sonnet 5"
    end

    test "leaves numeric parts as-is" do
      assert ModelLabel.humanize("claude-haiku-4-5-20251001") ==
               "Claude Haiku 4 5 20251001"
    end

    test "upcases known acronyms" do
      assert ModelLabel.humanize("gpt-5.1-codex-mini") == "GPT 5.1 Codex Mini"
    end
  end
end
