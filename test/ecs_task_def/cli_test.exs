defmodule EcsTaskDef.CLITest do
  use ExUnit.Case
  # NOT async: this file swaps PATH via the env argument only — but capture_io
  # of grouped stderr is simpler serialized.

  import ExUnit.CaptureIO
  import EcsTaskDef.TestSupport

  alias EcsTaskDef.CLI

  setup do
    dir = Path.join(System.tmp_dir!(), "cli-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp run_with_env(argv, env) do
    # CLI.run/2 takes the environment map for testability; run/1 delegates
    # with System.get_env().
    stderr = capture_io(:stderr, fn -> send(self(), {:code, CLI.run(argv, env)}) end)
    assert_received {:code, code}
    {code, stderr}
  end

  test "no args prints usage and exits 1" do
    {code, err} = run_with_env([], %{"PATH" => "/nonexistent"})
    assert code == 1
    assert err =~ "Usage:"
    assert err =~ "generate"
    assert err =~ "init"
  end

  test "unknown flag suggests the nearest real one and prints usage" do
    {code, err} = run_with_env(["generate", "in.pkl", "--ouput", "x"], %{"PATH" => "/nonexistent"})
    assert code == 1
    assert err =~ "unknown option --ouput"
    assert err =~ "did you mean --output?"
    assert err =~ "Usage:"
  end

  test "generate --help and init --help print usage with the version line and exit 0" do
    version = Application.spec(:ecs_task_def, :vsn) |> to_string()

    for argv <- [["--help"], ["generate", "--help"], ["init", "--help"]] do
      stdout = capture_io(fn -> send(self(), {:code, CLI.run(argv, %{"PATH" => "/nonexistent"})}) end)
      assert_received {:code, 0}
      assert stdout =~ "Usage:"
      assert stdout =~ "ecs-task-def #{version}"
      assert stdout =~ "awslabs@#{EcsTaskDef.SchemaPin.short_sha()}"
    end
  end

  test "missing pkl exits 2 with install hint" do
    {code, err} = run_with_env(["generate", "in.pkl"], %{"PATH" => "/nonexistent"})
    assert code == 2
    assert err =~ "pkl not found on PATH"
  end

  test "missing env file exits 3", %{dir: dir} do
    fake = fake_pkl_dir()
    input = Path.join(dir, "t.pkl")
    File.write!(input, "family = \"x\"\n")

    {code, err} =
      run_with_env(
        ["generate", input, "--env-file", Path.join(dir, "missing.env")],
        %{"PATH" => fake}
      )

    assert code == 3
    assert err =~ "cannot read env file"
  end

  test "pkl eval failure exits 4, header then pkl stderr", %{dir: dir} do
    fake = fake_pkl_dir()
    input = Path.join(dir, "t.pkl")
    File.write!(input, "irrelevant")
    System.put_env("FAKE_PKL_EXIT", "1")
    System.put_env("FAKE_PKL_STDERR", "-- Pkl Error --\nboom at line 3")
    on_exit(fn -> System.delete_env("FAKE_PKL_EXIT"); System.delete_env("FAKE_PKL_STDERR") end)

    {code, err} = run_with_env(["generate", input], %{"PATH" => fake})
    assert code == 4
    assert err =~ "pkl eval failed"
    assert err =~ "boom at line 3"
    # header comes before pkl's stderr
    assert :binary.match(err, "pkl eval failed") < :binary.match(err, "boom at line 3")
  end

  test "schema-invalid output exits 5 listing violations", %{dir: dir} do
    fake = fake_pkl_dir()
    input = Path.join(dir, "t.pkl")
    File.write!(input, "irrelevant")
    System.put_env("FAKE_PKL_STDOUT", ~s({"cpu": 256}))
    on_exit(fn -> System.delete_env("FAKE_PKL_STDOUT") end)

    {code, err} = run_with_env(["generate", input], %{"PATH" => fake})
    assert code == 5
    assert err =~ "schema validation failed"
    assert err =~ "cpu: Type mismatch"
    assert err =~ "family"
  end

  test "success writes JSON to stdout, progress to stderr", %{dir: dir} do
    fake = fake_pkl_dir()
    input = Path.join(dir, "t.pkl")
    File.write!(input, "irrelevant")

    System.put_env(
      "FAKE_PKL_STDOUT",
      ~s({"family":"x","containerDefinitions":[{"name":"c","image":"i"}]})
    )

    on_exit(fn -> System.delete_env("FAKE_PKL_STDOUT") end)

    stdout =
      capture_io(fn ->
        stderr = capture_io(:stderr, fn -> send(self(), {:code, CLI.run(["generate", input], %{"PATH" => fake})}) end)
        send(self(), {:stderr, stderr})
      end)

    assert_received {:code, 0}
    assert_received {:stderr, stderr}
    assert JSON.decode!(stdout)["family"] == "x"
    assert stderr =~ "✓ pkl 0.31.1 found"
    assert stderr =~ "✓ validated against ECS schema"
    assert stderr =~ "awslabs@#{EcsTaskDef.SchemaPin.short_sha()}"
  end

  test "-o writes the file and unwritable output dir exits 6", %{dir: dir} do
    fake = fake_pkl_dir()
    input = Path.join(dir, "t.pkl")
    File.write!(input, "irrelevant")

    System.put_env(
      "FAKE_PKL_STDOUT",
      ~s({"family":"x","containerDefinitions":[{"name":"c","image":"i"}]})
    )

    on_exit(fn -> System.delete_env("FAKE_PKL_STDOUT") end)

    out = Path.join(dir, "out.json")
    {code, err} = run_with_env(["generate", input, "-o", out], %{"PATH" => fake})
    assert code == 0
    assert err =~ "wrote #{out}"
    assert JSON.decode!(File.read!(out))["family"] == "x"

    bad_out = Path.join([dir, "no-such-dir", "out.json"])
    {code2, err2} = run_with_env(["generate", input, "--output", bad_out], %{"PATH" => fake})
    assert code2 == 6
    assert err2 =~ "cannot write"
  end

  test "init scaffolds and refuses to overwrite with exit 6", %{dir: dir} do
    {code, err} = run_with_env(["init", dir], %{"PATH" => "/nonexistent"})
    assert code == 0
    assert err =~ "created #{Path.join(dir, "mytask.pkl")}"

    {code2, err2} = run_with_env(["init", dir], %{"PATH" => "/nonexistent"})
    assert code2 == 6
    assert err2 =~ "already exist"
    assert err2 =~ "mytask.pkl"
  end
end
