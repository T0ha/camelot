defmodule Camelot.Telemetry.Context do
  @moduledoc """
  Global properties every PostHog capture carries.

  `test.camelotai.tech` and `app.camelotai.tech` report into a single
  PostHog project, so without an `environment` property every funnel
  silently mixes staging and production. The value mirrors the
  collector's `DEPLOYMENT_ENV` → `deployment.environment.name`
  (`otel-collector/gateway.yaml`), and deliberately defaults to the
  *non*-production value: an unset env var must never invent
  production data.

  `internal?/1` is the other half — it marks maintainer traffic so
  funnels can exclude it. Anything outside production counts as
  internal, as does the maintainer's own email.
  """

  @production "production"

  # Configured as a string rather than a `Regex` because release
  # `sys.config` cannot serialise a compiled regex on OTP 26+.
  @default_email_pattern ~r/^t0hashvein.*@gmail\.com$/i

  @doc """
  Deployment environment name, e.g. `"production"` or `"test"`.
  """
  @spec environment() :: String.t()
  def environment, do: config(:environment, "dev")

  @doc "Whether this deployment is the production one."
  @spec production?() :: boolean()
  def production?, do: environment() == @production

  @doc """
  Properties merged into every capture made through
  `Camelot.Telemetry.Capture`.
  """
  @spec global_properties() :: %{environment: String.t()}
  def global_properties, do: %{environment: environment()}

  @doc """
  Whether the given user (or bare email) is one of ours.

  Everything outside production is internal by definition — the test
  cluster is staff-only — and so is the maintainer's email in any
  environment. Client domains are *not* internal.
  """
  @spec internal?(%{email: String.t() | Ash.CiString.t()} | String.t() | nil) ::
          boolean()
  def internal?(nil), do: not production?()
  def internal?(%{email: email}), do: internal?(to_string(email))

  def internal?(email) do
    not production?() or Regex.match?(email_pattern(), String.trim(email))
  end

  @spec email_pattern() :: Regex.t()
  defp email_pattern, do: compile_pattern(config(:internal_email_pattern, nil))

  @spec compile_pattern(String.t() | Regex.t() | nil) :: Regex.t()
  defp compile_pattern(nil), do: @default_email_pattern
  defp compile_pattern(%Regex{} = pattern), do: pattern
  defp compile_pattern(pattern), do: Regex.compile!(pattern, "i")

  @spec config(atom(), String.t() | nil) :: String.t() | Regex.t() | nil
  defp config(key, default) do
    :camelot
    |> Application.get_env(:telemetry, [])
    |> Keyword.get(key, default)
  end
end
