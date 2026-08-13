defmodule Camelot.Runtime.Runner.LocalPortTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.Runner.LocalPort

  describe "read_task_file/2" do
    @tag :tmp_dir
    test "reads an absolute path from the local filesystem", %{tmp_dir: tmp} do
      path = Path.join(tmp, "plan.md")
      File.write!(path, "# Local plan")

      assert {:ok, "# Local plan"} = LocalPort.read_task_file("task-1", path)
    end

    @tag :tmp_dir
    test "errors on a missing file", %{tmp_dir: tmp} do
      path = Path.join(tmp, "absent.md")

      assert {:error, :enoent} = LocalPort.read_task_file("task-1", path)
    end
  end
end
