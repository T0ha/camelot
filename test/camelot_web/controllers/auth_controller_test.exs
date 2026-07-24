defmodule CamelotWeb.AuthControllerTest do
  use CamelotWeb.ConnCase, async: true

  alias Camelot.Accounts.User
  alias CamelotWeb.AuthController

  setup %{conn: conn} do
    user =
      Ash.Seed.seed!(User, %{email: "signed-in-#{System.unique_integer([:positive])}@example.com"})

    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
    user = %{user | __metadata__: Map.put(user.__metadata__, :token, token)}

    %{conn: Phoenix.ConnTest.init_test_session(conn, %{}), user: user}
  end

  test "emits [:camelot, :user, :signed_in] on success", %{conn: conn, user: user} do
    ref = :telemetry_test.attach_event_handlers(self(), [[:camelot, :user, :signed_in]])
    on_exit(fn -> :telemetry.detach(ref) end)

    AuthController.success(conn, {:strategy, :confirm}, user, "token")

    assert_received {[:camelot, :user, :signed_in], ^ref, %{}, %{user: received_user}}
    assert received_user.id == user.id
  end
end
