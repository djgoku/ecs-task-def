defmodule EcsTaskDef.OutputTest do
  use ExUnit.Case, async: true

  alias EcsTaskDef.Output

  setup do
    dir = Path.join(System.tmp_dir!(), "output-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "writes a new file", %{dir: dir} do
    path = Path.join(dir, "out.json")
    assert :ok = Output.write(path, ~s({"a":1}\n))
    assert File.read!(path) == ~s({"a":1}\n)
  end

  test "replaces an existing file atomically", %{dir: dir} do
    path = Path.join(dir, "out.json")
    File.write!(path, "old")
    assert :ok = Output.write(path, "new")
    assert File.read!(path) == "new"
  end

  test "on failure the existing destination is untouched and no temp remains", %{dir: dir} do
    missing_dir = Path.join(dir, "does-not-exist")
    path = Path.join(missing_dir, "out.json")
    assert {:error, message} = Output.write(path, "data")
    assert message =~ path
    refute File.exists?(missing_dir)
    assert File.ls!(dir) == []
  end
end
