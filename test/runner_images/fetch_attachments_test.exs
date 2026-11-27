defmodule Camelot.RunnerImages.FetchAttachmentsTest do
  @moduledoc """
  Runs `runner-images/base/fetch-attachments.sh` against `file://`
  URLs in a temp workspace. Skipped when `bash`, `curl` or `jq` is
  missing on the host.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../runner-images/base/fetch-attachments.sh", __DIR__)
  @tools ~w(bash curl jq)

  @moduletag skip:
               Enum.find_value(@tools, false, fn tool ->
                 System.find_executable(tool) == nil &&
                   "#{tool} is not installed"
               end)

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "fetch-attachments-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    src = Path.join(root, "src")
    File.mkdir_p!(Path.join(workspace, ".git"))
    File.mkdir_p!(src)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      workspace: workspace,
      dir: Path.join(workspace, ".camelot/attachments"),
      src: src
    }
  end

  defp source!(ctx, name, body) do
    path = Path.join(ctx.src, name)
    File.write!(path, body)
    "file://" <> path
  end

  defp run(ctx, entries) do
    env = [
      {"ATTACHMENTS_JSON", Jason.encode!(entries)},
      {"CAMELOT_ATTACHMENTS_DIR", ctx.dir},
      {"CAMELOT_WORKSPACE_DIR", ctx.workspace}
    ]

    System.cmd("bash", [@script], env: env, stderr_to_stdout: true)
  end

  test "downloads every listed file", ctx do
    url = source!(ctx, "a.xlsx", "sheet")

    assert {_, 0} =
             run(ctx, [%{filename: "report one.xlsx", url: url}])

    assert File.read!(Path.join(ctx.dir, "report one.xlsx")) == "sheet"
  end

  test "skips a file that already exists", ctx do
    File.mkdir_p!(ctx.dir)
    File.write!(Path.join(ctx.dir, "a.txt"), "kept")
    url = source!(ctx, "a.txt", "new")

    assert {_, 0} = run(ctx, [%{filename: "a.txt", url: url}])
    assert File.read!(Path.join(ctx.dir, "a.txt")) == "kept"
  end

  test "keeps only the basename of a traversing filename", ctx do
    url = source!(ctx, "evil", "x")

    assert {_, 0} = run(ctx, [%{filename: "../../evil", url: url}])
    assert File.exists?(Path.join(ctx.dir, "evil"))
    refute File.exists?(Path.join(ctx.workspace, "evil"))
  end

  test "skips `..` and empty names", ctx do
    url = source!(ctx, "x", "x")

    assert {out, 0} =
             run(ctx, [%{filename: "..", url: url}, %{filename: "", url: url}])

    assert out =~ "invalid name"
    assert File.ls!(ctx.dir) == []
  end

  test "a failed download is logged and does not fail", ctx do
    ok = source!(ctx, "ok.txt", "ok")
    missing = "file://" <> Path.join(ctx.src, "missing")

    assert {out, 0} =
             run(ctx, [
               %{filename: "gone.txt", url: missing},
               %{filename: "ok.txt", url: ok}
             ])

    assert out =~ "[camelot] failed to fetch attachment gone.txt"
    assert File.ls!(ctx.dir) == ["ok.txt"]
  end

  test "removes files no longer listed", ctx do
    File.mkdir_p!(ctx.dir)
    File.write!(Path.join(ctx.dir, "deleted.txt"), "old")
    url = source!(ctx, "b.txt", "b")

    assert {_, 0} = run(ctx, [%{filename: "b.txt", url: url}])
    assert File.ls!(ctx.dir) == ["b.txt"]
  end

  test "adds the git exclude line exactly once", ctx do
    url = source!(ctx, "c.txt", "c")

    assert {_, 0} = run(ctx, [%{filename: "c.txt", url: url}])
    assert {_, 0} = run(ctx, [%{filename: "c.txt", url: url}])

    exclude = File.read!(Path.join(ctx.workspace, ".git/info/exclude"))
    assert exclude == ".camelot/attachments/\n"
  end

  test "malformed JSON is ignored", ctx do
    env = [
      {"ATTACHMENTS_JSON", "not json"},
      {"CAMELOT_ATTACHMENTS_DIR", ctx.dir},
      {"CAMELOT_WORKSPACE_DIR", ctx.workspace}
    ]

    assert {_, 0} =
             System.cmd("bash", [@script], env: env, stderr_to_stdout: true)
  end
end
