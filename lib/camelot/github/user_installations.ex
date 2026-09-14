defmodule Camelot.Github.UserInstallations do
  @moduledoc """
  Discovers which GitHub App installations the *signed-in
  user* can see, and links them to their Camelot account.

  Used by the "Log in with GitHub" callback so a first-time
  user lands on the board already connected, instead of
  being sent to `/profile` for a second, manual step.
  GitHub's `GET /user/installations` payloads already have
  the exact shape `Camelot.Github.InstallationSync.upsert/1`
  consumes, so nothing needs normalising here.

  The user access token is used only for the duration of
  the request and never persisted.
  """

  alias Camelot.Accounts.User
  alias Camelot.Github.AppConfig
  alias Camelot.Github.Installation
  alias Camelot.Github.InstallationSync

  require Logger

  @url "https://api.github.com/user/installations"

  # This runs on the login critical path, so cap the wait
  # rather than letting a slow GitHub hold the redirect.
  @receive_timeout 10_000

  @doc """
  Lists the App installations visible to the holder of
  `access_token`.
  """
  @spec list(String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def list(nil), do: {:error, :no_access_token}

  def list(access_token) do
    if AppConfig.configured?() do
      request(access_token)
    else
      {:error, :not_configured}
    end
  end

  @doc """
  Upserts each installation payload and links it to `user`.

  Individual failures — most often an installation another
  Camelot user already claimed — are logged and skipped so
  one bad row can't cost the user the rest of them.
  """
  @spec link([map()], User.t()) :: :ok
  def link(payloads, %User{} = user) do
    Enum.each(payloads, &link_one(&1, user))
  end

  @doc """
  `list/1` followed by `link/2`.
  """
  @spec sync(String.t() | nil, User.t()) :: :ok | {:error, term()}
  def sync(access_token, %User{} = user) do
    case list(access_token) do
      {:ok, payloads} -> link(payloads, user)
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(access_token) do
    [
      url: @url,
      params: [per_page: 100],
      headers: [
        {"authorization", "Bearer #{access_token}"},
        {"accept", "application/vnd.github+json"}
      ],
      receive_timeout: @receive_timeout
    ]
    |> Req.get()
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"installations" => installations}}} ->
        {:ok, installations}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:error, {:unexpected_body, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp link_one(payload, user) do
    with {:ok, %Installation{} = installation} <- InstallationSync.upsert(payload),
         {:ok, _linked} <- link_user(installation, user) do
      :ok
    else
      {:error, reason} ->
        Logger.info(
          "GitHub login: skipping installation " <>
            "#{inspect(payload["id"])} for user #{user.id}: " <>
            inspect(reason)
        )

        :ok
    end
  end

  defp link_user(installation, user) do
    Ash.update(installation, %{user_id: user.id}, action: :link_user, actor: user)
  end
end
