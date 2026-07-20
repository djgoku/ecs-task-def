defmodule EcsTaskDef.Integration.GenerateTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias EcsTaskDef.CLI

  @moduletag :pkl

  setup do
    dir = Path.join(System.tmp_dir!(), "e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  # Captures each key's pre-existing value (nil if unset) so on_exit restores
  # the real process environment exactly as found, instead of blindly
  # deleting keys that may have carried a value before this test ran.
  defp put_env!(map) do
    originals = for {k, _} <- map, into: %{}, do: {k, System.get_env(k)}
    on_exit(fn -> restore_env!(originals) end)
    for {k, v} <- map, do: System.put_env(k, v)
  end

  defp delete_env!(key) do
    original = System.get_env(key)
    on_exit(fn -> restore_env!(%{key => original}) end)
    System.delete_env(key)
  end

  defp restore_env!(originals) do
    Enum.each(originals, fn
      {k, nil} -> System.delete_env(k)
      {k, v} -> System.put_env(k, v)
    end)
  end

  defp run(argv) do
    stderr = capture_io(:stderr, fn -> send(self(), {:code, CLI.run(argv, System.get_env())}) end)
    assert_received {:code, code}
    {code, stderr}
  end

  defp scaffold_vendor!(dir) do
    {0, _} = run(["init", dir, "--vendor"])
  end

  # exit 0 — happy path
  test "init --vendor then generate produces valid JSON end to end", %{dir: dir} do
    scaffold_vendor!(dir)
    put_env!(%{"ECR_REPO" => "123.dkr.ecr.us-east-1.amazonaws.com/web", "IMAGE_TAG" => "v1"})

    out = Path.join(dir, "task.json")
    {code, stderr} = run(["generate", Path.join(dir, "mytask.pkl"), "-o", out])

    assert code == 0
    assert stderr =~ "✓ evaluated"
    doc = out |> File.read!() |> JSON.decode!()
    assert doc["family"] == "my-app"

    assert hd(doc["containerDefinitions"])["image"] ==
             "123.dkr.ecr.us-east-1.amazonaws.com/web:v1"

    assert :ok = EcsTaskDef.Validator.validate(doc)
  end

  # exit 1 — usage error
  test "unknown flag exits 1 with usage and suggestion", %{dir: dir} do
    {code, stderr} = run(["generate", Path.join(dir, "x.pkl"), "--ouput", "y"])
    assert code == 1
    assert stderr =~ "did you mean --output?"
    assert stderr =~ "Usage:"
  end

  # exit 2 — pkl missing (env map PATH is authoritative for preflight)
  test "missing pkl exits 2 with install hint", %{dir: dir} do
    stderr =
      capture_io(:stderr, fn ->
        send(
          self(),
          {:code, CLI.run(["generate", Path.join(dir, "x.pkl")], %{"PATH" => "/nonexistent"})}
        )
      end)

    assert_received {:code, 2}
    assert stderr =~ "pkl not found on PATH"
    assert stderr =~ "brew install pkl"
  end

  # exit 3 — malformed env file
  test "malformed env file exits 3 with file:line", %{dir: dir} do
    scaffold_vendor!(dir)
    env_file = Path.join(dir, ".env")
    File.write!(env_file, "FOO=ok\nnot a pair\n")

    {code, stderr} = run(["generate", Path.join(dir, "mytask.pkl"), "--env-file", env_file])
    assert code == 3
    assert stderr =~ "#{env_file}:2:"
  end

  # exit 4 — pkl eval failure (missing env var), header before pkl stderr
  test "missing env var: exit 4 and pkl's file:line error surfaces", %{dir: dir} do
    scaffold_vendor!(dir)
    put_env!(%{"ECR_REPO" => "repo"})
    delete_env!("IMAGE_TAG")

    {code, stderr} = run(["generate", Path.join(dir, "mytask.pkl")])
    assert code == 4
    assert stderr =~ "pkl eval failed"
    assert stderr =~ "Cannot find resource `env:IMAGE_TAG`"
    assert stderr =~ "mytask.pkl"

    assert :binary.match(stderr, "pkl eval failed") <
             :binary.match(stderr, "Cannot find resource")
  end

  # exit 4 variant — typo'd field caught by the typed module
  test "typo'd field in the template fails eval with the field name", %{dir: dir} do
    scaffold_vendor!(dir)
    put_env!(%{"ECR_REPO" => "r", "IMAGE_TAG" => "t"})

    task = Path.join(dir, "mytask.pkl")
    File.write!(task, String.replace(File.read!(task), "networkMode", "networkMoode"))

    {code, stderr} = run(["generate", task])
    assert code == 4
    assert stderr =~ "networkMoode"
  end

  # exit 5 — schema validation failure (free-form pkl bypasses the typed module)
  test "schema-invalid output exits 5 listing violations", %{dir: dir} do
    freeform = Path.join(dir, "freeform.pkl")
    File.write!(freeform, "cpu = 256\n")

    {code, stderr} = run(["generate", freeform])
    assert code == 5
    assert stderr =~ "schema validation failed"
    assert stderr =~ "cpu: Type mismatch"
    assert stderr =~ "family"
  end

  # exit 6 — cannot write output
  test "unwritable output path exits 6 with the path and OS reason", %{dir: dir} do
    scaffold_vendor!(dir)
    put_env!(%{"ECR_REPO" => "r", "IMAGE_TAG" => "t"})

    bad_out = Path.join([dir, "no-such-dir", "out.json"])
    {code, stderr} = run(["generate", Path.join(dir, "mytask.pkl"), "-o", bad_out])
    assert code == 6
    assert stderr =~ "cannot write #{bad_out}"
  end

  # env-file precedence + shadow warning end to end
  test "env file supplies defaults; real env wins with shadow warning", %{dir: dir} do
    scaffold_vendor!(dir)
    put_env!(%{"ECR_REPO" => "from-env"})
    delete_env!("IMAGE_TAG")

    env_file = Path.join(dir, ".env")
    File.write!(env_file, "ECR_REPO=from-file\nIMAGE_TAG=file-tag\n")

    out = Path.join(dir, "task.json")

    {code, stderr} =
      run(["generate", Path.join(dir, "mytask.pkl"), "-o", out, "--env-file", env_file])

    assert code == 0
    assert stderr =~ "warning: ECR_REPO is set in both the environment and #{env_file}"
    refute stderr =~ "from-file"
    doc = out |> File.read!() |> JSON.decode!()
    assert hd(doc["containerDefinitions"])["image"] == "from-env:file-tag"
  end
end
