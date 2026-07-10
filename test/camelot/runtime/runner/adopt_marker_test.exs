defmodule Camelot.Runtime.Runner.AdoptMarkerTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.Runner.AdoptMarker

  test "path/1 names the per-session marker file" do
    assert AdoptMarker.path("abc-123") == "/tmp/camelot-exit-abc-123"
  end

  describe "parse/1" do
    test "parses a plain exit code" do
      assert {:ok, 0} = AdoptMarker.parse("0")
      assert {:ok, 1} = AdoptMarker.parse("1")
      assert {:ok, 137} = AdoptMarker.parse("137")
    end

    test "tolerates a trailing newline and surrounding whitespace" do
      assert {:ok, 0} = AdoptMarker.parse("0\n")
      assert {:ok, 2} = AdoptMarker.parse("  2  \n")
    end

    test "empty output (absent marker via `cat` of a missing file) is :none" do
      assert :none = AdoptMarker.parse("")
      assert :none = AdoptMarker.parse("   \n")
    end

    test "non-numeric content is :none" do
      assert :none = AdoptMarker.parse("cat: /tmp/camelot-exit-x: No such file")
    end

    test "non-binary input is :none" do
      assert :none = AdoptMarker.parse(nil)
      assert :none = AdoptMarker.parse(:error)
    end
  end
end
