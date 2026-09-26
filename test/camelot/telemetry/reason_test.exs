defmodule Camelot.Telemetry.ReasonTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Invalid
  alias Camelot.Telemetry.Reason

  describe "classify/1" do
    test "passes through the bounded atoms the GitHub connect flow returns" do
      for reason <- [
            :missing_state,
            :not_authenticated,
            :actor_mismatch,
            :invalid_installation_id,
            :not_configured
          ] do
        assert Reason.classify(reason) == {reason, nil}
      end
    end

    test "unwraps an {:error, reason} tuple" do
      assert Reason.classify({:error, :actor_mismatch}) == {:actor_mismatch, nil}
    end

    test "maps HTTP statuses onto the reason they mean to a user" do
      assert Reason.classify({:http_error, 404, %{}}) == {:not_found, 404}
      assert Reason.classify({:http_error, 403, %{}}) == {:forbidden, 403}
      assert Reason.classify({:http_error, 429, %{}}) == {:rate_limited, 429}
      assert Reason.classify({:http_error, 502, %{}}) == {:http_error, 502}
    end

    test "tags the two write failures of the connect flow" do
      assert Reason.classify({:upsert_failed, %Invalid{}}) == {:upsert_failed, nil}
      assert Reason.classify({:link_failed, %Invalid{}}) == {:link_failed, nil}
    end

    test "maps Phoenix.Token verification failures" do
      assert Reason.classify(:invalid) == {:invalid_state, nil}
      assert Reason.classify(:expired) == {:expired_state, nil}
    end

    test "an unknown term degrades to :unknown rather than leaking a string" do
      assert Reason.classify({:some, "unexpected", %{shape: 1}}) == {:unknown, nil}
      assert Reason.classify("boom") == {:unknown, nil}
    end

    test "every reason it can return is a documented member of the enum" do
      terms = [
        :missing_state,
        :not_authenticated,
        :actor_mismatch,
        :invalid_installation_id,
        :not_configured,
        :no_installation,
        :invalid,
        :expired,
        {:http_error, 404, %{}},
        {:http_error, 500, %{}},
        {:upsert_failed, :x},
        {:link_failed, :x},
        "anything else"
      ]

      for term <- terms do
        {reason, _http_status} = Reason.classify(term)
        assert reason in Reason.reasons()
      end
    end
  end

  describe "changeset_summary/1" do
    test "reports the failing fields and error types, never the messages" do
      error = %Invalid{
        errors: [
          %Ash.Error.Changes.Required{field: :name, type: :attribute},
          %Ash.Error.Changes.InvalidAttribute{field: :github_repo_url, message: "is invalid"}
        ]
      }

      assert Reason.changeset_summary(error) == %{
               error_fields: ["github_repo_url", "name"],
               error_codes: ["invalid_attribute", "required"]
             }
    end

    test "an unrecognised error still yields a bounded summary" do
      assert Reason.changeset_summary(:nope) == %{error_fields: [], error_codes: ["unknown_error"]}
    end
  end
end
