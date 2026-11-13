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

    test "extracts a non-image `files/` upload inserted as a plain link" do
      url = "https://github.com/user-attachments/files/34787789/report.xlsx"
      body = "Numbers are in [report.xlsx](#{url}), please use them."

      assert IssueAttachments.extract_urls(body) == [url]
    end

    test "extracts a private-user-images link" do
      url = "https://private-user-images.githubusercontent.com/1/2-shot.png?jwt=abc"

      assert IssueAttachments.extract_urls("![shot](#{url})") == [url]
    end

    test "ignores a plain link to a non-GitHub host" do
      body = "See [the docs](https://example.com/guide.pdf) and https://example.com/a.zip"

      assert IssueAttachments.extract_urls(body) == []
    end

    test "keeps a trailing `)` or `]` out of the url" do
      url = "https://github.com/user-attachments/files/1/a.csv"
      body = "([a.csv](#{url})) [#{url}]"

      assert IssueAttachments.extract_urls(body) == [url]
    end

    test "preserves order across markdown images and attachment links" do
      file = "https://github.com/user-attachments/files/1/a.pdf"
      image = "https://example.com/b.png"
      body = "[a.pdf](#{file}) then ![b](#{image})"

      assert IssueAttachments.extract_urls(body) == [file, image]
    end
  end

  describe "filename_for/1" do
    test "uses the decoded last path segment" do
      url = "https://github.com/user-attachments/files/1/Q3%20report.xlsx"

      assert IssueAttachments.filename_for(url) == "Q3 report.xlsx"
    end

    test "never lets a decoded name escape the attachments dir" do
      url = "https://github.com/user-attachments/files/1/..%2F..%2Fetc%2Fpasswd"

      assert IssueAttachments.filename_for(url) == ".._.._etc_passwd"
    end

    test "falls back to `attachment` for an empty or dot-only name" do
      assert IssueAttachments.filename_for("https://github.com/") == "attachment"
      assert IssueAttachments.filename_for("https://github.com/user-attachments/files/1/..") == "attachment"
    end
  end

  describe "unique_filename/2" do
    test "keeps a free name" do
      assert IssueAttachments.unique_filename("a.xlsx", MapSet.new()) == "a.xlsx"
    end

    test "suffixes a taken name before its extension" do
      taken = MapSet.new(["a.xlsx", "a-2.xlsx"])

      assert IssueAttachments.unique_filename("a.xlsx", taken) == "a-3.xlsx"
    end

    test "suffixes a taken name without an extension" do
      assert IssueAttachments.unique_filename("log", MapSet.new(["log"])) == "log-2"
    end
  end

  describe "localize_links/2" do
    test "points an imported url at its local copy" do
      url = "https://github.com/user-attachments/files/1/a.xlsx"
      attachment = %{source_url: url, filename: "a.xlsx"}

      assert IssueAttachments.localize_links("[a.xlsx](#{url})", [attachment]) ==
               "[a.xlsx](.camelot/attachments/a.xlsx)"
    end

    test "leaves text without imported urls alone" do
      assert IssueAttachments.localize_links("no links", [%{source_url: nil, filename: "x"}]) == "no links"
      assert IssueAttachments.localize_links(nil, []) == ""
    end
  end
end
