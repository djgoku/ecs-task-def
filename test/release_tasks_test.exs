defmodule EcsTaskDef.ReleaseTasksTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("..", __DIR__)
  @version Mix.Project.config()[:version]
  @release_tag "ecs-task-def@#{@version}"

  setup do
    fixture =
      Path.join(
        System.tmp_dir!(),
        "ecs-task-def-release-tasks-#{System.unique_integer([:positive])}"
      )

    bin_dir = Path.join(fixture, "bin")
    state_dir = Path.join(fixture, "state")
    gh_log = Path.join(fixture, "gh.log")
    upload_dir = Path.join(fixture, "uploads")

    File.mkdir_p!(Path.join(fixture, "pkl"))
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(state_dir)
    File.mkdir_p!(upload_dir)
    File.cp!(Path.join(@repo_root, "mise.toml"), Path.join(fixture, "mise.toml"))
    File.cp!(Path.join(@repo_root, "mix.exs"), Path.join(fixture, "mix.exs"))

    File.cp!(
      Path.join(@repo_root, "pkl/PklProject"),
      Path.join(fixture, "pkl/PklProject")
    )

    fake_gh = Path.join(bin_dir, "gh")
    File.cp!(Path.join(@repo_root, "test/support/fake_gh.sh"), fake_gh)
    File.chmod!(fake_gh, 0o755)

    File.write!(gh_log, "")

    on_exit(fn -> File.rm_rf(fixture) end)

    %{
      bin_dir: bin_dir,
      fixture: fixture,
      gh_log: gh_log,
      state_dir: state_dir,
      upload_dir: upload_dir
    }
  end

  test "release-ensure creates the full release tag", context do
    {output, status} = run_task(context, "release-ensure", "create-ok")

    assert status == 0, output

    assert gh_lines(context) == [
             "release create #{@release_tag} --verify-tag --title #{@release_tag} " <>
               "--notes Automated\\ release\\ for\\ #{@release_tag}."
           ]
  end

  test "release-ensure accepts a create-create race only after viewing the release", context do
    {output, status} = run_task(context, "release-ensure", "create-race")

    assert status == 0, output

    assert gh_lines(context) == [
             "release create #{@release_tag} --verify-tag --title #{@release_tag} " <>
               "--notes Automated\\ release\\ for\\ #{@release_tag}.",
             "release view #{@release_tag}"
           ]
  end

  test "release-ensure rejects a fatal create failure", context do
    {output, status} = run_task(context, "release-ensure", "create-fatal")

    assert status != 0
    assert output =~ "::error::gh release create failed and no release exists"

    assert gh_lines(context) == [
             "release create #{@release_tag} --verify-tag --title #{@release_tag} " <>
               "--notes Automated\\ release\\ for\\ #{@release_tag}.",
             "release view #{@release_tag}"
           ]
  end

  test "release-publish-binaries uploads exact binaries and valid SHA-256 sidecars",
       context do
    create_valid_binaries(context.fixture)

    {output, status} = run_task(context, "release-publish-binaries", "create-ok")

    assert status == 0, output
    assert uploaded_asset_names(context) == binary_asset_names()

    shasum = System.find_executable("shasum") || raise "shasum is required"

    for arch <- ["aarch64", "x86_64"] do
      name = "ecs-task-def-#{host_os()}_#{arch}"
      source = File.read!(binary_path(context.fixture, arch))
      captured_binary = Path.join(context.upload_dir, name)
      captured_checksum = Path.join(context.upload_dir, "#{name}.sha256")

      assert File.read!(captured_binary) == source

      digest =
        source
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert File.read!(captured_checksum) == "#{digest}  #{name}\n"

      {check_output, check_status} =
        System.cmd(shasum, ["-a", "256", "-c", "#{name}.sha256"],
          cd: context.upload_dir,
          stderr_to_stdout: true
        )

      assert check_status == 0, check_output
      assert check_output =~ "#{name}: OK"
    end
  end

  test "release-publish-binaries stops before GitHub mutation when shasum fails",
       context do
    create_valid_binaries(context.fixture)

    fake_shasum = Path.join(context.bin_dir, "shasum")
    File.write!(fake_shasum, "#!/usr/bin/env bash\nexit 73\n")
    File.chmod!(fake_shasum, 0o755)

    {output, status} = run_task(context, "release-publish-binaries", "create-ok")

    assert status != 0, "checksum failure unexpectedly succeeded:\n#{output}"
    assert_no_github_mutation(context, :checksum_failure)
    assert File.ls!(context.upload_dir) == []
  end

  for scenario <- [:extra, :missing, :wrong_name, :directory, :symlink, :non_executable] do
    test "release-publish-binaries rejects #{scenario} artifacts before GitHub mutation",
         context do
      scenario = unquote(scenario)
      create_valid_binaries(context.fixture)
      mutate_binaries(context.fixture, scenario)

      {output, status} = run_task(context, "release-publish-binaries", "create-ok")

      assert status != 0, "#{scenario} unexpectedly succeeded:\n#{output}"
      assert_no_github_mutation(context, scenario)
    end
  end

  test "release-publish-pkl uploads the four exact versioned package artifacts", context do
    create_valid_pkl_artifacts(context.fixture)

    {output, status} = run_task(context, "release-publish-pkl", "create-ok")

    assert status == 0, output

    expected =
      Enum.map(pkl_artifact_names(), fn name ->
        "release upload #{@release_tag} pkl/.out/ecs-task-def@#{@version}/#{name} --clobber"
      end)

    assert upload_lines(context) == expected
  end

  for scenario <- [:extra, :missing, :wrong_name, :directory, :symlink, :unreadable] do
    test "release-publish-pkl rejects #{scenario} artifacts before GitHub mutation", context do
      scenario = unquote(scenario)
      create_valid_pkl_artifacts(context.fixture)
      mutate_pkl_artifacts(context.fixture, scenario)

      {output, status} = run_task(context, "release-publish-pkl", "create-ok")

      assert status != 0, "#{scenario} unexpectedly succeeded:\n#{output}"
      assert_no_github_mutation(context, scenario)
    end
  end

  test "release-validate-tag reports a focused diagnostic when the Mix version is missing",
       context do
    mix_file = Path.join(context.fixture, "mix.exs")

    mix_file
    |> File.read!()
    |> String.replace(~r/^\s*version:\s*"[^"]+",$/m, "      # version intentionally absent")
    |> then(&File.write!(mix_file, &1))

    {output, status} = run_task(context, "release-validate-tag", "create-ok")

    assert status != 0
    assert output =~ "::error::could not parse version from mix.exs ('')"
  end

  test "release-validate-tag reports a focused diagnostic when the Pkl version is missing",
       context do
    project_file = Path.join(context.fixture, "pkl/PklProject")

    project_file
    |> File.read!()
    |> String.replace(~r/^\s*version = "[^"]+".*$/m, "  // version intentionally absent")
    |> then(&File.write!(project_file, &1))

    {output, status} = run_task(context, "release-validate-tag", "create-ok")

    assert status != 0
    assert output =~ "or pkl/PklProject ('')"
  end

  defp run_task(context, task, mode) do
    mise = System.find_executable("mise") || raise "mise is required for release task tests"
    File.write!(context.gh_log, "")

    env = [
      {"FAKE_GH_LOG", context.gh_log},
      {"FAKE_GH_MODE", mode},
      {"FAKE_GH_UPLOAD_DIR", context.upload_dir},
      {"GH_TOKEN", "fake-token"},
      {"MISE_AUTO_INSTALL", "0"},
      {"MISE_DISABLE_TOOLS", "gh"},
      {"MISE_TRUSTED_CONFIG_PATHS", Path.join(context.fixture, "mise.toml")},
      {"PATH", context.bin_dir <> ":" <> System.fetch_env!("PATH")},
      {"RELEASE_TAG", @release_tag},
      {"XDG_STATE_HOME", context.state_dir}
    ]

    System.cmd(mise, ["run", task],
      cd: context.fixture,
      env: env,
      stderr_to_stdout: true
    )
  end

  defp create_valid_binaries(fixture) do
    directory = Path.join(fixture, "burrito_out")
    File.mkdir_p!(directory)

    for path <- binary_paths(fixture) do
      File.write!(path, "binary fixture for #{Path.basename(path)}\n")
      File.chmod!(path, 0o755)
    end
  end

  defp mutate_binaries(fixture, :extra) do
    path = Path.join(fixture, "burrito_out/ecs_task_def_#{host_os()}_debug")
    File.write!(path, "extra\n")
    File.chmod!(path, 0o755)
  end

  defp mutate_binaries(fixture, :missing) do
    fixture |> binary_path("x86_64") |> File.rm!()
  end

  defp mutate_binaries(fixture, :wrong_name) do
    source = binary_path(fixture, "x86_64")
    File.rename!(source, Path.join(Path.dirname(source), "ecs_task_def_#{host_os()}_amd64"))
  end

  defp mutate_binaries(fixture, :directory) do
    path = binary_path(fixture, "x86_64")
    File.rm!(path)
    File.mkdir!(path)
  end

  defp mutate_binaries(fixture, :symlink) do
    path = binary_path(fixture, "x86_64")
    target = Path.join(fixture, "binary-symlink-target")
    File.rm!(path)
    File.write!(target, "target\n")
    File.chmod!(target, 0o755)
    File.ln_s!(target, path)
  end

  defp mutate_binaries(fixture, :non_executable) do
    fixture |> binary_path("x86_64") |> File.chmod!(0o644)
  end

  defp binary_paths(fixture) do
    Enum.map(["aarch64", "x86_64"], &binary_path(fixture, &1))
  end

  defp binary_path(fixture, arch) do
    Path.join(fixture, "burrito_out/ecs_task_def_#{host_os()}_#{arch}")
  end

  defp create_valid_pkl_artifacts(fixture) do
    directory = pkl_artifact_directory(fixture)
    File.mkdir_p!(directory)

    for name <- pkl_artifact_names() do
      File.write!(Path.join(directory, name), "package fixture\n")
    end
  end

  defp mutate_pkl_artifacts(fixture, :extra) do
    File.write!(Path.join(pkl_artifact_directory(fixture), "unexpected"), "extra\n")
  end

  defp mutate_pkl_artifacts(fixture, :missing) do
    fixture |> pkl_artifact_path("ecs-task-def@#{@version}.zip.sha256") |> File.rm!()
  end

  defp mutate_pkl_artifacts(fixture, :wrong_name) do
    source = pkl_artifact_path(fixture, "ecs-task-def@#{@version}.zip")
    File.rename!(source, Path.join(Path.dirname(source), "ecs-task-def@#{@version}.tgz"))
  end

  defp mutate_pkl_artifacts(fixture, :directory) do
    path = pkl_artifact_path(fixture, "ecs-task-def@#{@version}.zip")
    File.rm!(path)
    File.mkdir!(path)
  end

  defp mutate_pkl_artifacts(fixture, :symlink) do
    path = pkl_artifact_path(fixture, "ecs-task-def@#{@version}.zip")
    target = Path.join(fixture, "pkl-symlink-target")
    File.rm!(path)
    File.write!(target, "target\n")
    File.ln_s!(target, path)
  end

  defp mutate_pkl_artifacts(fixture, :unreadable) do
    fixture
    |> pkl_artifact_path("ecs-task-def@#{@version}.zip")
    |> File.chmod!(0o000)
  end

  defp pkl_artifact_names do
    [
      "ecs-task-def@#{@version}",
      "ecs-task-def@#{@version}.sha256",
      "ecs-task-def@#{@version}.zip",
      "ecs-task-def@#{@version}.zip.sha256"
    ]
  end

  defp pkl_artifact_directory(fixture) do
    Path.join(fixture, "pkl/.out/ecs-task-def@#{@version}")
  end

  defp pkl_artifact_path(fixture, name) do
    Path.join(pkl_artifact_directory(fixture), name)
  end

  defp gh_lines(context) do
    context.gh_log
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp upload_lines(context) do
    Enum.filter(gh_lines(context), &String.starts_with?(&1, "release upload "))
  end

  defp binary_asset_names do
    for arch <- ["aarch64", "x86_64"],
        suffix <- ["", ".sha256"] do
      "ecs-task-def-#{host_os()}_#{arch}#{suffix}"
    end
  end

  defp uploaded_asset_names(context) do
    Enum.map(upload_lines(context), fn line ->
      ["release", "upload", @release_tag, path, "--clobber"] = String.split(line)

      Path.basename(path)
    end)
  end

  defp assert_no_github_mutation(context, scenario) do
    mutation? = fn line ->
      String.starts_with?(line, "release create ") or
        String.starts_with?(line, "release upload ")
    end

    refute Enum.any?(gh_lines(context), mutation?),
           "#{scenario} reached release create or release upload:\n#{File.read!(context.gh_log)}"
  end

  defp host_os do
    case :os.type() do
      {:unix, :darwin} -> "macos"
      {:unix, :linux} -> "linux"
      other -> raise "unsupported release-task test host: #{inspect(other)}"
    end
  end
end
