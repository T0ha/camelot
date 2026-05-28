defmodule Camelot.Agents.AgentTemplate do
  @moduledoc """
  Configuration template for an AI coding agent CLI.

  One row per agent type (e.g. `claude_code`, `codex`).
  Holds the executable name, base CLI args, per-stage
  permission arguments, output parser choice, env vars,
  and an optional `command_prefix` for running the agent
  inside Docker, a terminal emulator, or any other wrapper.

  Per-project tweaks are expressed as nullable
  `*_override` columns on `Camelot.Agents.Agent`.
  """
  use Ash.Resource,
    domain: Camelot.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: []

  @parsers [:claude_code_json, :raw_text]

  postgres do
    table("agent_templates")
    repo(Camelot.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :slug, :string do
      allow_nil?(false)
      public?(true)
      description("Stable identifier, e.g. claude_code, codex")
    end

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
      description("Human-readable name shown in the UI")
    end

    attribute :command_prefix, :string do
      allow_nil?(true)
      public?(true)

      description(
        "Optional wrapper prepended to the executable. " <>
          "Whitespace-tokenized at dispatch. Supports the " <>
          "{{project_path}} placeholder. Example: " <>
          "`docker run --rm -v {{project_path}}:/w -w /w img`"
      )
    end

    attribute :executable, :string do
      allow_nil?(false)
      public?(true)
      description("CLI binary name, resolved via PATH")
    end

    attribute :base_args, {:array, :string} do
      allow_nil?(false)
      public?(true)
      default([])
      description("Static args prepended before stage/tool/prompt args")
    end

    attribute :prompt_flag, :string do
      allow_nil?(true)
      public?(true)
      description("Flag for the prompt (e.g. -p); nil = positional")
    end

    attribute :tools_flag, :string do
      allow_nil?(true)
      public?(true)
      description("Flag for the allowed-tools list (e.g. --allowedTools)")
    end

    attribute :tools_separator, :string do
      allow_nil?(false)
      public?(true)
      default(",")
    end

    attribute :permission_args_by_stage, :map do
      allow_nil?(false)
      public?(true)
      default(%{})

      description(
        "Map of task stage (string) to extra CLI args, " <>
          ~s(e.g. %{"planning" => ["--permission-mode", "plan"]})
      )
    end

    attribute :internal_tools, {:array, :string} do
      allow_nil?(false)
      public?(true)
      default([])
      description("Tool names filtered out of the allowed_tools list")
    end

    attribute :env_vars, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
      description("Environment variables passed to the CLI port")
    end

    attribute :parser, :atom do
      allow_nil?(false)
      public?(true)
      default(:raw_text)
      constraints(one_of: @parsers)
      description("Output parser strategy")
    end

    attribute :pr_url_pattern, :string do
      allow_nil?(false)
      public?(true)
      default("https://github\\.com/[^\\s]+/pull/(\\d+)")
      description("Regex for extracting the PR URL + number from output")
    end

    attribute :question_phrases, {:array, :string} do
      allow_nil?(false)
      public?(true)
      default([])
      description("Phrases that mark output as a clarifying question")
    end

    attribute :base_retry_delay_ms, :integer do
      allow_nil?(false)
      public?(true)
      default(5_000)
      description("Initial retry delay; doubled per attempt")
    end

    timestamps()
  end

  relationships do
    has_many :agents, Camelot.Agents.Agent do
      destination_attribute(:template_id)
    end
  end

  identities do
    identity(:unique_slug, [:slug])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :slug,
        :name,
        :command_prefix,
        :executable,
        :base_args,
        :prompt_flag,
        :tools_flag,
        :tools_separator,
        :permission_args_by_stage,
        :internal_tools,
        :env_vars,
        :parser,
        :pr_url_pattern,
        :question_phrases,
        :base_retry_delay_ms
      ])
    end

    update :update do
      primary?(true)

      accept([
        :name,
        :command_prefix,
        :executable,
        :base_args,
        :prompt_flag,
        :tools_flag,
        :tools_separator,
        :permission_args_by_stage,
        :internal_tools,
        :env_vars,
        :parser,
        :pr_url_pattern,
        :question_phrases,
        :base_retry_delay_ms
      ])
    end
  end
end
