defmodule Camelot.Github.IssueAttachmentsTest do
  use ExUnit.Case, async: true

  alias Camelot.Github.IssueAttachments

  describe "extract_urls/1" do
    test "is empty for a nil body" do
      assert IssueAttachments.extract_urls(nil) == []
    end

    test "is empty when there are no images/links" do
      assert IssueAttachments.extract_urls("Just some plain text, no attachments.") == []
    end

    test "extracts a markdown image link" do
      body = "Here's a screenshot:\n\n![screenshot](https://example.com/screenshot.png)\n\nThanks!"

      assert IssueAttachments.extract_urls(body) == ["https://example.com/screenshot.png"]
    end

    test "extracts a GitHub user-attachments CDN link pasted as a markdown image" do
      url = "https://github.com/user-attachments/assets/12345678-90ab-cdef-1234-567890abcdef"
      body = "![image](#{url})"

      assert IssueAttachments.extract_urls(body) == [url]
    end

    test "extracts a bare user-attachments CDN link (non-image file, no markdown wrapper)" do
      url = "https://github.com/user-attachments/assets/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
      body = "I attached a log file: #{url}\n\nplease check it"

      assert IssueAttachments.extract_urls(body) == [url]
    end

    test "extracts a legacy user-images.githubusercontent.com link" do
      url = "https://user-images.githubusercontent.com/123/456-screenshot.png"
      body = "![old-style](#{url})"

      assert IssueAttachments.extract_urls(body) == [url]
    end

    test "extracts multiple distinct urls, preserving first-occurrence order" do
      body = """
      ![one](https://example.com/one.png)
      Some text.
      ![two](https://example.com/two.png)
      """

      assert IssueAttachments.extract_urls(body) == [
               "https://example.com/one.png",
               "https://example.com/two.png"
             ]
    end

    test "dedupes a repeated url" do
      body = "![a](https://example.com/dup.png) and again ![b](https://example.com/dup.png)"

      assert IssueAttachments.extract_urls(body) == ["https://example.com/dup.png"]
    end
  end
end
