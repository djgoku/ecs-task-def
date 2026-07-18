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
    {code, err} =
      run_with_env(["generate", "in.pkl", "--ouput", "x"], %{"PATH" => "/nonexistent"})

    assert code == 1
    assert err =~ "unknown option --ouput"
    assert err =~ "did you mean --output?"
    assert err =~ "Usage:"
  end

  test "known string option missing its value gets a specific error, no self-referential suggestion" do
    {code, err} = run_with_env(["generate", "in.pkl", "--env-file"], %{"PATH" => "/nonexistent"})
    assert code == 1
    assert err =~ "option --env-file requires a value"
    refute err =~ "did you mean --env-file?"
    assert err =~ "Usage:"
  end

  test "known string option short alias missing its value gets a specific error" do
    {code, err} = run_with_env(["generate", "in.pkl", "-o"], %{"PATH" => "/nonexistent"})
    assert code == 1
    assert err =~ "option -o requires a value"
    refute err =~ "did you mean -o?"
    assert err =~ "Usage:"
  end

  test "genuinely unknown option still gets the nearest-flag suggestion, not a requires-a-value error" do
    {code, err} = run_with_env(["generate", "in.pkl", "--ouput"], %{"PATH" => "/nonexistent"})
    assert code == 1
    assert err =~ "unknown option --ouput"
    assert err =~ "did you mean --output?"
    refute err =~ "requires a value"
  end

  test "a flag valid for another command but not this one is rejected without a self-suggestion" do
    {code, err} =
      run_with_env(["generate", "in.pkl", "--vendor"], %{"PATH" => "/nonexistent"})

    assert code == 1
    assert err =~ "option --vendor is not valid for this command"
    refute err =~ "did you mean --vendor?"
    assert err =~ "Usage:"
  end

  test "a known boolean flag given a value is rejected without a self-suggestion", %{dir: dir} do
    {code, err} = run_with_env(["init", dir, "--vendor=nope"], %{"PATH" => "/nonexistent"})

    assert code == 1
    assert err =~ "option --vendor does not take a value"
    refute err =~ "did you mean --vendor?"
    assert err =~ "Usage:"
  end

  test "--help given a value is rejected without a self-suggestion, on both commands" do
    for argv <- [["generate", "in.pkl", "--help=nope"], ["init", "--help=nope"]] do
      {code, err} = run_with_env(argv, %{"PATH" => "/nonexistent"})

      assert code == 1
      assert err =~ "option --help does not take a value"
      refute err =~ "did you mean --help?"
      assert err =~ "Usage:"
    end
  end

  test "init rejects generate-only flags without a self-suggestion", %{dir: dir} do
    {code, err} =
      run_with_env(["init", dir, "--output", "x"], %{"PATH" => "/nonexistent"})

    assert code == 1
    assert err =~ "option --output is not valid for this command"
    refute err =~ "did you mean --output?"
    assert err =~ "Usage:"
  end

  test "generate --help and init --help print usage with the version line and exit 0" do
    version = Application.spec(:ecs_task_def, :vsn) |> to_string()

    for argv <- [["--help"], ["generate", "--help"], ["init", "--help"]] do
      stdout =
        capture_io(fn -> send(self(), {:code, CLI.run(argv, %{"PATH" => "/nonexistent"})}) end)

      assert_received {:code, 0}
      assert stdout =~ "Usage:"
      assert stdout =~ "ecs-task-def #{version}"
      assert stdout =~ "awslabs@#{EcsTaskDef.SchemaPin.short_sha()}"
    end
  end

  test "--help renders real CLI flag spellings, not NimbleOptions internal atom keys" do
    stdout =
      capture_io(fn ->
        send(self(), {:code, CLI.run(["--help"], %{"PATH" => "/nonexistent"})})
      end)

    assert_received {:code, 0}

    for flag <- ["--output", "-o", "--env-file", "--vendor", "--help", "-h"] do
      assert stdout =~ flag
    end

    refute stdout =~ "`:output`"
    refute stdout =~ "`:env_file`"
    refute stdout =~ "`:vendor`"
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

    on_exit(fn ->
      System.delete_env("FAKE_PKL_EXIT")
      System.delete_env("FAKE_PKL_STDERR")
    end)

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

  test "non-object pkl output exits 5 with a root type violation instead of crashing", %{dir: dir} do
    fake = fake_pkl_dir()
    input = Path.join(dir, "t.pkl")
    File.write!(input, "irrelevant")
    System.put_env("FAKE_PKL_STDOUT", "null")
    on_exit(fn -> System.delete_env("FAKE_PKL_STDOUT") end)

    {code, err} = run_with_env(["generate", input], %{"PATH" => fake})
    assert code == 5
    assert err =~ "schema validation failed"
    assert err =~ "Type mismatch. Expected Object but got Null."
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
        stderr =
          capture_io(:stderr, fn ->
            send(self(), {:code, CLI.run(["generate", input], %{"PATH" => fake})})
          end)

        send(self(), {:stderr, stderr})
      end)

    assert_received {:code, 0}
    assert_received {:stderr, stderr}
    assert JSON.decode!(stdout)["family"] == "x"
    assert stderr =~ "✓ pkl 0.31.1 found"
    assert stderr =~ "✓ validated against ECS schema"
    assert stderr =~ "awslabs@#{EcsTaskDef.SchemaPin.short_sha()}"
  end

  test "env-file value reaches the pkl child when not present in the process environment", %{
    dir: dir
  } do
    fake = fake_pkl_dir()
    input = Path.join(dir, "t.pkl")
    File.write!(input, "irrelevant")

    json = ~s({"family":"from-env-file","containerDefinitions":[{"name":"c","image":"i"}]})
    env_file = Path.join(dir, "vars.env")
    File.write!(env_file, "FAKE_PKL_STDOUT=#{json}\n")

    stdout =
      capture_io(fn ->
        stderr =
          capture_io(:stderr, fn ->
            send(
              self(),
              {:code, CLI.run(["generate", input, "--env-file", env_file], %{"PATH" => fake})}
            )
          end)

        send(self(), {:stderr, stderr})
      end)

    assert_received {:code, 0}
    assert_received {:stderr, _stderr}
    assert JSON.decode!(stdout)["family"] == "from-env-file"
  end

  test "process env wins over the env-file, and the spawned child sees the real process value, not the injected map value",
       %{dir: dir} do
    fake = fake_pkl_dir()
    input = Path.join(dir, "t.pkl")
    File.write!(input, "irrelevant")

    real_json =
      ~s({"family":"real-process-env","containerDefinitions":[{"name":"c","image":"i"}]})

    env_file_json = ~s({"family":"env-file","containerDefinitions":[{"name":"c","image":"i"}]})

    injected_json =
      ~s({"family":"injected-map","containerDefinitions":[{"name":"c","image":"i"}]})

    env_file = Path.join(dir, "vars.env")
    File.write!(env_file, "FAKE_PKL_STDOUT=#{env_file_json}\n")

    System.put_env("FAKE_PKL_STDOUT", real_json)
    on_exit(fn -> System.delete_env("FAKE_PKL_STDOUT") end)

    stdout =
      capture_io(fn ->
        stderr =
          capture_io(:stderr, fn ->
            send(
              self(),
              {:code,
               CLI.run(
                 ["generate", input, "--env-file", env_file],
                 %{"PATH" => fake, "FAKE_PKL_STDOUT" => injected_json}
               )}
            )
          end)

        send(self(), {:stderr, stderr})
      end)

    assert_received {:code, 0}
    assert_received {:stderr, stderr}
    assert stderr =~ "warning: FAKE_PKL_STDOUT is set in both the environment and #{env_file}"
    assert JSON.decode!(stdout)["family"] == "real-process-env"
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

  test "init --vendor scaffolds both files and the starter amends the local schema", %{dir: dir} do
    {code, err} = run_with_env(["init", dir, "--vendor"], %{"PATH" => "/nonexistent"})

    assert code == 0
    assert err =~ "created #{Path.join(dir, "mytask.pkl")}"
    assert err =~ "created #{Path.join(dir, "EcsSchema.pkl")}"
    assert File.exists?(Path.join(dir, "mytask.pkl"))
    assert File.exists?(Path.join(dir, "EcsSchema.pkl"))
    assert File.read!(Path.join(dir, "mytask.pkl")) =~ ~s(amends "EcsSchema.pkl")
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
