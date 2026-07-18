defmodule EcsTaskDef.PreflightTest do
  use ExUnit.Case, async: true

  alias EcsTaskDef.Preflight
  import EcsTaskDef.TestSupport

  test "finds pkl on PATH and returns its version" do
    dir = fake_pkl_dir()
    assert {:ok, path, "0.31.1"} = Preflight.check(%{"PATH" => dir})
    assert path == Path.join(dir, "pkl")
  end

  test "missing pkl yields an actionable error" do
    assert {:error, message} = Preflight.check(%{"PATH" => "/nonexistent-dir"})
    assert message =~ "pkl not found on PATH"
    assert message =~ "brew install pkl"
    assert message =~ "mise use pkl"
  end

  test "too-old pkl yields an error naming both versions" do
    dir = fake_pkl_dir()
    assert {:error, message} = Preflight.check(%{"PATH" => dir, "FAKE_PKL_VERSION" => "0.25.0"})
    assert message =~ "0.25.0"
    assert message =~ "0.31.1 or newer"
  end

  test "unparseable version output yields an error" do
    dir = fake_pkl_dir()
    assert {:error, message} = Preflight.check(%{"PATH" => dir, "FAKE_PKL_VERSION" => "banana"})
    assert message =~ "could not parse"
  end
end
