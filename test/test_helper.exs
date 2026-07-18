defmodule EcsTaskDef.TestSupport do
  @doc """
  Creates a temp dir containing an executable named `pkl` that runs
  test/support/fake_pkl.sh, and returns that dir (for PATH injection).
  """
  def fake_pkl_dir do
    dir = Path.join(System.tmp_dir!(), "fake-pkl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    fake = Path.expand("test/support/fake_pkl.sh")
    File.ln_s!(fake, Path.join(dir, "pkl"))
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end

exclude = if System.find_executable("pkl"), do: [], else: [pkl: true]

if exclude != [] do
  IO.puts("NOTE: pkl not found on PATH — skipping :pkl integration tests")
end

ExUnit.start(exclude: exclude)
