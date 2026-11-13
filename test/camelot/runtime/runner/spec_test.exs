defmodule Camelot.Runtime.Runner.SpecTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.Runner.Spec

  defp spec(json), do: %Spec{session_id: "s1", owner_pid: self(), argv: ["true"], attachments_json: json}

  describe "attachments_env/1" do
    test "is empty when the task has no attachments" do
      assert Spec.attachments_env(spec(nil)) == []
    end

    test "passes the attachments listing through" do
      json = ~s([{"filename":"a.xlsx","url":"http://x/a"}])

      assert Spec.attachments_env(spec(json)) == ["ATTACHMENTS_JSON=#{json}"]
    end
  end
end
