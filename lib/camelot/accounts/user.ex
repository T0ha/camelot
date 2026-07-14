defmodule Camelot.Accounts.User do
  @moduledoc """
  User resource with magic link authentication.
  """
  use Ash.Resource,
    domain: Camelot.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication],
    authorizers: [Ash.Policy.Authorizer]

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
    end

    add_ons do
      confirmation :confirm_new_user do
        monitor_fields([:email])
        confirm_on_create?(true)
        confirm_on_update?(false)
        require_interaction?(true)
        auto_confirm_actions([:sign_in_with_magic_link])

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

    many_to_many :projects, Camelot.Projects.Project do
      through(Camelot.Projects.Membership)
      source_attribute_on_join_resource(:user_id)
      destination_attribute_on_join_resource(:project_id)
    end

    has_many :agents, Camelot.Agents.Agent do
      destination_attribute(:user_id)
    end
  end

  identities do
    identity(:unique_email, [:email])
  end

  changes do
    # Server-generated Ed25519 SSH key on every user creation —
    # covers both admin :create_user and magic-link
    # :sign_in_with_magic_link (the auto-generated upsert that
    # creates new users on first sign-in).
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
  end

  policies do
    # Auth flows (sign-in, token, confirmation) run pre-actor or with the user
    # as actor on themselves. They are explicitly bypassed by AshAuthentication.
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end

    # Read is open: managed relationship lookups from other resources
    # (Agent.user, Membership.user, etc.) need to find users without an
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
  end
end
