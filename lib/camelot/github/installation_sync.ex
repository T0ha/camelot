defmodule Camelot.Github.InstallationSync do
  @moduledoc """
  Upserts `Camelot.Github.Installation` rows from GitHub's
  installation JSON payload. Shared by
  `CamelotWeb.GithubSetupController` (initial link, from
  `GET /app/installations/:id`) and
  `CamelotWeb.GithubWebhookController` (`installation`
  webhook events), so both entry points normalise the
  same way.
  """

  alias Camelot.Github.Installation

  require Ash.Query

  @spec upsert(map()) :: {:ok, Installation.t()} | {:error, term()}
  def upsert(%{"id" => installation_id} = gh_installation) do
    account = gh_installation["account"] || %{}

    Installation
    |> Ash.Changeset.for_create(
      :upsert,
      %{
        installation_id: installation_id,
        account_login: account["login"],
        account_type: normalize_account_type(account["type"])
      },
      authorize?: false
    )
    |> Ash.create()
  end

  @spec suspend(map()) :: :ok
  def suspend(%{"id" => installation_id}), do: update_action(installation_id, :suspend)

  @spec unsuspend(map()) :: :ok
  def unsuspend(%{"id" => installation_id}), do: update_action(installation_id, :unsuspend)

  @spec delete(map()) :: :ok
  def delete(%{"id" => installation_id}) do
    case find(installation_id) do
      {:ok, %Installation{} = installation} -> Ash.destroy(installation, authorize?: false)
      _ -> :ok
    end

    :ok
  end

  defp update_action(installation_id, action) do
    case find(installation_id) do
      {:ok, %Installation{} = installation} ->
        Ash.update(installation, %{}, action: action, authorize?: false)

      _ ->
        :ok
    end

    :ok
  end

  defp find(installation_id) do
    Installation
    |> Ash.Query.filter(installation_id == ^installation_id)
    |> Ash.read_one(authorize?: false)
  end

  defp normalize_account_type("Organization"), do: :organization
  defp normalize_account_type(_), do: :user
end
