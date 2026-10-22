defmodule Camelot.Accounts.User.Validations.KnownTimeZone do
  @moduledoc """
  Accepts only IANA zone names the bundled tz database knows, so
  `Camelot.TimeZone` can always shift into the user's zone.
  """
  use Ash.Resource.Validation

  @impl true
  @spec validate(Ash.Changeset.t(), keyword(), map()) :: :ok | {:error, keyword()}
  def validate(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.get_attribute(:time_zone)
    |> Tzdata.zone_exists?()
    |> result()
  end

  defp result(true), do: :ok
  defp result(false), do: {:error, field: :time_zone, message: "is not a known time zone"}
end
