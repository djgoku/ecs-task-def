defmodule EcsTaskDef.PklTest do
  use ExUnit.Case, async: true

  alias EcsTaskDef.Pkl
  import EcsTaskDef.TestSupport

  defp fake_pkl do
    Path.join(fake_pkl_dir(), "pkl")
  end

  test "success returns stdout and separately captured stderr" do
    System.put_env("FAKE_PKL_STDOUT", ~s({"family":"x"}))
    System.put_env("FAKE_PKL_STDERR", "some warning")
    on_exit(fn -> System.delete_env("FAKE_PKL_STDOUT"); System.delete_env("FAKE_PKL_STDERR") end)

    assert {:ok, out, stderr} = Pkl.eval(fake_pkl(), "ignored.pkl", [])
    assert out == ~s({"family":"x"}\n)
    assert stderr == "some warning\n"
  end

  test "failure returns exit code and captured stderr" do
    System.put_env("FAKE_PKL_EXIT", "42")
    System.put_env("FAKE_PKL_STDERR", "-- Pkl Error --\nboom")
    on_exit(fn -> System.delete_env("FAKE_PKL_EXIT"); System.delete_env("FAKE_PKL_STDERR") end)

    assert {:error, {42, stderr}} = Pkl.eval(fake_pkl(), "ignored.pkl", [])
    assert stderr =~ "Pkl Error"
    assert stderr =~ "boom"
  end

  test "extra_env reaches the child process" do
    # fake_pkl echoes FAKE_PKL_STDOUT; set it ONLY via extra_env
    assert {:ok, out, _} = Pkl.eval(fake_pkl(), "ignored.pkl", [{"FAKE_PKL_STDOUT", "from-extra"}])
    assert out == "from-extra\n"
  end

  @tag :pkl
  test "real pkl evaluates a trivial module to JSON" do
    dir = Path.join(System.tmp_dir!(), "pkl-eval-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    input = Path.join(dir, "t.pkl")
    File.write!(input, "name = \"hello \\(read(\"env:WHO\"))\"\n")

    pkl = System.find_executable("pkl")
    assert {:ok, out, _stderr} = Pkl.eval(pkl, input, [{"WHO", "world"}])
    assert JSON.decode!(out) == %{"name" => "hello world"}
  end

  @tag :pkl
  test "real pkl missing env var fails with file:line in stderr" do
    dir = Path.join(System.tmp_dir!(), "pkl-eval-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    input = Path.join(dir, "t.pkl")
    File.write!(input, "name = read(\"env:DOES_NOT_EXIST_XYZ\")\n")

    pkl = System.find_executable("pkl")
    assert {:error, {code, stderr}} = Pkl.eval(pkl, input, [])
    assert code != 0
    assert stderr =~ "Cannot find resource `env:DOES_NOT_EXIST_XYZ`"
    assert stderr =~ "t.pkl"
  end
end
