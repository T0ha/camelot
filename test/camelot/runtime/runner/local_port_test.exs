defmodule Camelot.Runtime.Runner.LocalPortTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.Runner.LocalPort
  alias Camelot.Runtime.Runner.Spec

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

  describe "output schema" do
    test "materialises the schema at the path the argv already names" do
      session_id = "lp-schema-#{System.unique_integer([:positive])}"
      path = Spec.output_schema_path(session_id)
      on_exit(fn -> File.rm(path) end)

      schema = ~s({"type":"object","additionalProperties":false})

      spec = %Spec{
        session_id: session_id,
        owner_pid: self(),
        argv: ["true", "--output-schema", path],
        output_schema_json: schema
      }

      {:ok, handle} = LocalPort.start(spec)
      assert_receive {:runner_exit, ^handle, 0}, 5_000

      # The container backends get this from exec-wrapper.sh; on the
      # host LocalPort has to write it itself, at the same path.
      assert File.read!(path) == schema
    end

    test "starts normally when the stage has no schema" do
      session_id = "lp-noschema-#{System.unique_integer([:positive])}"

      spec = %Spec{
        session_id: session_id,
        owner_pid: self(),
        argv: ["true"],
        output_schema_json: nil
      }

      {:ok, handle} = LocalPort.start(spec)
      assert_receive {:runner_exit, ^handle, 0}, 5_000

      refute File.exists?(Spec.output_schema_path(session_id))
    end
  end
end
