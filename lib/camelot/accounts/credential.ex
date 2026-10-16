defmodule Camelot.Accounts.Credential do
  @moduledoc """
  An encrypted credential belonging to a user — API key
  or SSH key — used by runner containers to authenticate
  against external services.

  GitHub auth is not a credential kind here: it's either
  the App-token path (`Camelot.Github.InstallationTokenCache`,
  automatic per-project once a GitHub App installation is
  linked) or the `:ssh_private_key` kind below.

  Values are encrypted at rest via `AshCloak` against
  `Camelot.Vault`. The encryption key comes from the
  `ENCRYPTION_KEY` env var in production (fail-hard if
  missing); dev/test use a stable key from `config/*.exs`.
  """
  use Ash.Resource,
    domain: Camelot.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak],
    authorizers: [],
    simple_notifiers: [Camelot.Telemetry.Notifier]

  require Ash.Query

  # `:codex_api_key` was retired in favour of `:openai_api_key`: both
  # mounted the same `OPENAI_API_KEY`, nothing ever branched on the
  # difference, and offering both made a user's choice load-bearing
  # when it wasn't (see
  # `20260925110000_retire_codex_api_key_credential_kind.exs`). Kinds
  # name the provider, not the agent CLI that happens to read them —
  # `:claude_api_key`, not `:claude_code_api_key`.
  @kinds [
    :claude_api_key,
    :openai_api_key,
    :ssh_private_key,
    :generic
  ]

  @doc "Currently-valid credential kinds."
  @spec valid_kinds() :: [atom()]
  def valid_kinds, do: @kinds

  postgres do
    table("credentials")
    repo(Camelot.Repo)
  end

  cloak do
    vault(Camelot.Vault)
    attributes([:value])
  end

  attributes do
    uuid_primary_key(:id)

    attribute :kind, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @kinds)
      description("Credential type — drives where it's mounted in the runner")
    end

    attribute :name, :string do
      allow_nil?(true)
      public?(true)
      description("Optional label, useful for :generic")
    end

    attribute :value, :string do
      allow_nil?(false)
      public?(true)
      sensitive?(true)
      # Secrets are opaque — Ash's default trim?: true silently dropped
      # the trailing newline from OpenSSH private keys, leaving us with
      # files OpenSSH would reject as "invalid format".
      constraints(trim?: false, allow_empty?: false)
      description("Secret value, encrypted at rest via AshCloak")
    end

    attribute :metadata, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
      description("Non-secret context (e.g. OAuth expiry, key fingerprint)")
    end

    attribute :usage_limited_until, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)

      description(
        "Set while the provider is rejecting requests against this " <>
          "credential as over its usage limit. Cleared once the " <>
          "window resets or the value is rotated."
      )
    end

    attribute :usage_limit_window, :string do
      allow_nil?(true)
      public?(true)

      description(
        "Human-readable rate-limit window reported by the provider " <>
          "the last time it rejected a request, e.g. \"5h\"."
      )
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Camelot.Accounts.User do
      allow_nil?(false)
    end
  end

  identities do
    identity(:unique_kind_per_user, [:user_id, :kind, :name])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:kind, :name, :value, :metadata])

      argument :user_id, :uuid do
        allow_nil?(false)
      end

      change(manage_relationship(:user_id, :user, type: :append))
    end

    update :update do
      primary?(true)
      accept([:name, :value, :metadata])
      require_atomic?(false)

      change(set_attribute(:usage_limited_until, nil))
      change(set_attribute(:usage_limit_window, nil))
    end

    update :rotate do
      accept([:value])
      require_atomic?(false)

      # Optional partial metadata override — callers rotating an
      # ssh_private_key pass {public_key, fingerprint, algorithm} so
      # those derived fields stay in lock-step with `value` rather than
      # being patched in a second action.
      argument(:metadata, :map, allow_nil?: true)

      change(set_attribute(:usage_limited_until, nil))
      change(set_attribute(:usage_limit_window, nil))

      change(fn changeset, _ ->
        existing = Ash.Changeset.get_attribute(changeset, :metadata) || %{}
        override = Ash.Changeset.get_argument(changeset, :metadata) || %{}

        merged =
          existing
          |> Map.merge(override)
          |> Map.put("rotated_at", DateTime.to_iso8601(DateTime.utc_now()))

        Ash.Changeset.change_attribute(changeset, :metadata, merged)
      end)
    end

    # Recovery once a usage-limited credential's reset time passes —
    # see `Camelot.Board.UsageLimitPause.resume_due/1`.
    update :clear_usage_limit do
      accept([])

      change(set_attribute(:usage_limited_until, nil))
      change(set_attribute(:usage_limit_window, nil))
    end

    # The provider rejected a request against this credential as
    # over-limit — see `Camelot.Board.UsageLimitPause.pause/3`.
    update :mark_usage_limited do
      accept([])
      require_atomic?(false)

      argument :usage_limited_until, :utc_datetime_usec do
        allow_nil?(false)
      end

      argument :usage_limit_window, :string do
        allow_nil?(true)
      end

      change(fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(
          :usage_limited_until,
          Ash.Changeset.get_argument(changeset, :usage_limited_until)
        )
        |> Ash.Changeset.force_change_attribute(
          :usage_limit_window,
          Ash.Changeset.get_argument(changeset, :usage_limit_window)
        )
      end)
    end
  end

  @doc """
  Looks up a user's credential of `kind`, or `nil`. Shared by
  `Camelot.Runtime.TaskRunner.build_secrets/2` (which needs the
  decrypted `value`, hence `load_value?: true`) and
  `Camelot.Board.UsageLimitPause` (which only inspects/updates the
  row itself).
  """
  @spec for_user_and_kind(String.t(), atom(), keyword()) :: t() | nil
  def for_user_and_kind(user_id, kind, opts \\ []) do
    query =
      __MODULE__
      |> Ash.Query.filter(user_id == ^user_id and kind == ^kind)
      |> Ash.Query.limit(1)

    query =
      if Keyword.get(opts, :load_value?, false) do
        Ash.Query.load(query, :value)
      else
        query
      end

    case Ash.read(query) do
      {:ok, [credential | _]} -> credential
      _ -> nil
    end
  end
end
