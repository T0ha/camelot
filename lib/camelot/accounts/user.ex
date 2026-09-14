defmodule Camelot.Accounts.User do
  @moduledoc """
  User resource with magic-link and "Log in with GitHub"
  authentication.

  GitHub sign-in is anchored on `github_user_id` (GitHub's
  stable numeric id) with email only as a fallback, so a
  user who changes their primary email on GitHub keeps the
  same Camelot account instead of silently forking a second
  one.
  """
  use Ash.Resource,
    domain: Camelot.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication],
    authorizers: [Ash.Policy.Authorizer]

  alias Camelot.Accounts.User.Secrets

  postgres do
    table("users")
    repo(Camelot.Repo)
  end

  authentication do
    tokens do
      enabled?(true)
      token_resource(Camelot.Accounts.Token)
      require_token_presence_for_authentication?(true)
      store_all_tokens?(true)

      signing_secret(fn _, _ ->
        Application.fetch_env(
          :camelot,
          :token_signing_secret
        )
      end)
    end

    strategies do
      magic_link do
        identity_field(:email)
        registration_enabled?(true)
        require_interaction?(true)

        sender(Camelot.Accounts.User.Senders.SendMagicLink)
      end

      # Everything else about this strategy (base_url,
      # authorize_url, token_url, user_url, user_emails_url,
      # scope, icon) is pre-set by
      # AshAuthentication.Strategy.Github.Dsl — don't restate it.
      github do
        client_id(Secrets)
        client_secret(Secrets)
        redirect_uri(Secrets)
        registration_enabled?(true)
      end
    end

    add_ons do
      confirmation :confirm_new_user do
        monitor_fields([:email])
        confirm_on_create?(false)
        confirm_on_update?(false)
        require_interaction?(true)
        auto_confirm_actions([:sign_in_with_magic_link, :register_with_github])

        sender(Camelot.Accounts.User.Senders.SendConfirmationEmail)
      end
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :email, :ci_string do
      allow_nil?(false)
      public?(true)
    end

    attribute :role, :atom do
      constraints(one_of: [:admin, :user])
      default(:user)
      allow_nil?(false)
      public?(true)
    end

    attribute :swarm_node_label, :string do
      allow_nil?(true)
      public?(true)

      description(
        "Swarm node label pinning this user's runners. " <>
          "Containers run only on nodes matching " <>
          "`node.labels.camelot-home == <value>`."
      )
    end

    attribute :github_user_id, :string do
      allow_nil?(true)

      description(
        "GitHub's numeric user id (assent's `sub` claim), " <>
          "stringified. Stable across GitHub email changes, so " <>
          "it — not the email — identifies a returning account."
      )
    end

    attribute :github_email_declined, :ci_string do
      allow_nil?(true)

      description(
        "GitHub email the user explicitly chose NOT to adopt. " <>
          "Suppresses re-prompting for that same address."
      )
    end

    attribute :notify_on_waiting_for_input, :boolean do
      allow_nil?(false)
      public?(true)
      default(true)
      description("Email this user when one of their task cards needs input.")
    end

    attribute :notify_on_error, :boolean do
      allow_nil?(false)
      public?(true)
      default(true)
      description("Email this user when one of their task cards errors.")
    end

    attribute :notify_on_done, :boolean do
      allow_nil?(false)
      public?(true)
      default(true)
      description("Email this user when one of their task cards is done.")
    end

    timestamps()
  end

  relationships do
    has_many :credentials, Camelot.Accounts.Credential do
      destination_attribute(:user_id)
    end

    has_many :github_installations, Camelot.Github.Installation do
      destination_attribute(:user_id)
    end

    many_to_many :projects, Camelot.Projects.Project do
      through(Camelot.Projects.Membership)
      source_attribute_on_join_resource(:user_id)
      destination_attribute_on_join_resource(:project_id)
    end
  end

  identities do
    identity(:unique_email, [:email])
    identity(:unique_github_user_id, [:github_user_id])
  end

  changes do
    # Server-generated Ed25519 SSH key on every user creation —
    # covers both admin :create_user and magic-link
    # :sign_in_with_magic_link (the auto-generated upsert that
    # creates new users on first sign-in). :register_with_github
    # is an upsert — i.e. a create — so GitHub sign-ins run it
    # too; it is idempotent, so a returning user only pays for
    # one extra Credential lookup.
    change(Camelot.Accounts.User.Changes.EnsureDefaultSshKey, on: [:create])
  end

  actions do
    defaults([:read])

    create :create_user do
      accept([:email, :role])
      change(set_attribute(:confirmed_at, &DateTime.utc_now/0))
      change(Camelot.Accounts.User.Changes.SendInvitationEmail)
    end

    update :set_swarm_node_label do
      accept([:swarm_node_label])
    end

    update :update_notification_preferences do
      accept([
        :notify_on_waiting_for_input,
        :notify_on_error,
        :notify_on_done
      ])
    end

    update :set_role do
      accept([:role])
      require_atomic?(false)
    end

    # Only :register_with_github, no :sign_in_with_github —
    # OAuth2.Plug dispatches :register whenever
    # registration_enabled? is true, and this upsert covers both
    # brand new and returning accounts.
    #
    # upsert_fields is deliberately only [:github_user_id]: Ash's
    # default ("every changing attribute") would overwrite role,
    # swarm_node_label, notification preferences and — crucially —
    # email on every login. The email can only ever move through
    # :adopt_github_email, which the user has to confirm.
    create :register_with_github do
      argument :user_info, :map do
        allow_nil?(false)
      end

      argument :oauth_tokens, :map do
        allow_nil?(false)
        sensitive?(true)
      end

      upsert?(true)
      upsert_identity(:unique_email)
      upsert_fields([:github_user_id])

      change(Camelot.Accounts.User.Changes.ApplyGithubUserInfo)
      change(Camelot.Accounts.User.Changes.ResolveGithubIdentity)
      change(Camelot.Accounts.User.Changes.GateGithubRegistration)
      change(AshAuthentication.GenerateTokenChange)
    end

    update :adopt_github_email do
      accept([:email])
      require_atomic?(false)
      change(set_attribute(:github_email_declined, nil))
    end

    update :decline_github_email do
      argument :email, :ci_string do
        allow_nil?(false)
      end

      require_atomic?(false)
      change(set_attribute(:github_email_declined, arg(:email)))
    end
  end

  policies do
    # Auth flows (sign-in, token, confirmation) run pre-actor or with the user
    # as actor on themselves. They are explicitly bypassed by AshAuthentication.
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end

    # Read is open: managed relationship lookups from other resources
    # (Task.creator, Membership.user, etc.) need to find users without an
    # authenticated actor. The admin-only listing in /admin/users is gated
    # at the LiveView mount, not at the resource layer.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:create_user) do
      authorize_if(actor_attribute_equals(:role, :admin))
    end

    policy action(:set_role) do
      authorize_if(actor_attribute_equals(:role, :admin))
    end

    policy action(:set_swarm_node_label) do
      authorize_if(expr(id == ^actor(:id)))
      authorize_if(actor_attribute_equals(:role, :admin))
    end

    policy action(:update_notification_preferences) do
      authorize_if(expr(id == ^actor(:id)))
    end

    policy action([:adopt_github_email, :decline_github_email]) do
      authorize_if(expr(id == ^actor(:id)))
    end
  end
end
