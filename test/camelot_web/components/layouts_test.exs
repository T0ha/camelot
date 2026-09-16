defmodule CamelotWeb.LayoutsTest do
  use ExUnit.Case, async: true

  alias CamelotWeb.Layouts

  describe "docs_url/1" do
    test "replaces a leading app. label with docs." do
      assert Layouts.docs_url("https://app.camelotai.tech") ==
               "https://docs.camelotai.tech"
    end

    test "prefixes docs. on hosts without an app. label" do
      assert Layouts.docs_url("https://test.camelotai.tech") ==
               "https://docs.test.camelotai.tech"
    end

    test "keeps a non-default port" do
      assert Layouts.docs_url("http://localhost:4000") ==
               "http://docs.localhost:4000"
    end
  end
end
