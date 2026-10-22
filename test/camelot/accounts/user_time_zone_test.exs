defmodule Camelot.Accounts.UserTimeZoneTest do
  use Camelot.DataCase, async: true

  test "defaults to Etc/UTC" do
    assert user!().time_zone == "Etc/UTC"
  end

  test ":set_time_zone accepts an IANA zone and rejects anything else" do
    user = user!()

    assert {:ok, %{time_zone: "Europe/Berlin"}} =
             Ash.update(user, %{time_zone: "Europe/Berlin"},
               action: :set_time_zone,
               actor: user
             )

    assert {:error, _} =
             Ash.update(user, %{time_zone: "Mars/Olympus"}, action: :set_time_zone, actor: user)
  end

  test "only the user themselves may change it" do
    user = user!()

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(user, %{time_zone: "Europe/Berlin"},
               action: :set_time_zone,
               actor: user!()
             )
  end
end
