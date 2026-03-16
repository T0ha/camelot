defmodule Camelot.Accounts.User do
  @moduledoc """
  User resource with magic link authentication.
  """
  use Ash.Resource,
    domain: Camelot.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication],
    authorizers: []

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

        sender(
          Camelot.Accounts.User.Senders.SendMagicLink
        )
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

    timestamps()
  end

  identities do
    identity(:unique_email, [:email])
  end

  actions do
    defaults([:read])
  end
end
