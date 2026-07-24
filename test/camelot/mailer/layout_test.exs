defmodule Camelot.Mailer.LayoutTest do
  use ExUnit.Case, async: true

  alias Camelot.Mailer.Layout

  describe "html/1" do
    test "wraps inner content in the branded shell" do
      html = Layout.html("<p>hello there</p>")

      assert html =~ "Camelot AI"
      assert html =~ "MedievalSharp"
      assert html =~ "#1a1a2e"
      assert html =~ "<p>hello there</p>"
    end
  end

  describe "button/2" do
    test "renders a purple CTA button linking to the given url" do
      html = Layout.button("https://example.com/go", "Go now")

      assert html =~ "#7c3aed"
      assert html =~ "https://example.com/go"
      assert html =~ "Go now"
    end
  end

  describe "fallback_link/1" do
    test "renders the gray fallback paragraph with a purple link" do
      html = Layout.fallback_link("https://example.com/go")

      assert html =~ "#666666"
      assert html =~ "#7c3aed"
      assert html =~ "https://example.com/go"
    end
  end
end
