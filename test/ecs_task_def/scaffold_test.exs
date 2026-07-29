defmodule EcsTaskDef.ScaffoldTest do
  use ExUnit.Case, async: true

  alias EcsTaskDef.Scaffold

  @repo_root Path.expand("../..", __DIR__)
  @canonical_package_base "package://pkg.pkl-lang.org/github.com/djgoku/ecs-task-def/ecs-task-def"
  @canonical_release_base "https://github.com/djgoku/ecs-task-def/releases/download/"

  setup do
    dir = Path.join(System.tmp_dir!(), "scaffold-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "default init writes mytask.pkl amending the versioned package URL", %{dir: dir} do
    assert {:ok, [task_path]} = Scaffold.init(dir, false)
    assert task_path == Path.join(dir, "mytask.pkl")
    contents = File.read!(task_path)
    version = Application.spec(:ecs_task_def, :vsn) |> to_string()

    assert contents =~
             ~s[amends "package://pkg.pkl-lang.org/github.com/djgoku/ecs-task-def/ecs-task-def@#{version}#/EcsSchema.pkl"]

    assert contents =~ ~s[read("env:]
  end

  test "Pkl metadata and scaffold use the same canonical coordinate", %{dir: dir} do
    project = File.read!(Path.join(@repo_root, "pkl/PklProject"))

    assert project =~ ~s[baseUri = "#{@canonical_package_base}"]
    assert project =~ ~s[packageZipUrl = "#{@canonical_release_base}]

    assert [_, package_base] =
             Regex.run(~r/^\s*baseUri = "([^"]+)"$/m, project)

    assert [_, pkl_version] =
             Regex.run(~r/^\s*version = "([^"]+)"/m, project)

    app_version = Application.spec(:ecs_task_def, :vsn) |> to_string()
    assert pkl_version == app_version

    assert {:ok, [task_path]} = Scaffold.init(dir, false)

    assert File.read!(task_path) =~
             ~s[amends "#{package_base}@#{app_version}#/EcsSchema.pkl"]
  end

  test "vendor init writes both files and amends the local module", %{dir: dir} do
    assert {:ok, paths} = Scaffold.init(dir, true)
    assert Path.join(dir, "mytask.pkl") in paths
    assert Path.join(dir, "EcsSchema.pkl") in paths
    assert File.read!(Path.join(dir, "mytask.pkl")) =~ ~s[amends "EcsSchema.pkl"]
    assert File.read!(Path.join(dir, "EcsSchema.pkl")) =~ "module EcsSchema"
  end

  test "refuses to overwrite and writes nothing", %{dir: dir} do
    File.write!(Path.join(dir, "EcsSchema.pkl"), "existing")
    assert {:error, {:exists, [conflict]}} = Scaffold.init(dir, true)
    assert conflict == Path.join(dir, "EcsSchema.pkl")
    refute File.exists?(Path.join(dir, "mytask.pkl"))
    assert File.read!(Path.join(dir, "EcsSchema.pkl")) == "existing"
  end

  test "does not follow a dangling symlink at a target", %{dir: dir} do
    target = Path.join(dir, "outside.pkl")
    task_path = Path.join(dir, "mytask.pkl")
    File.ln_s!(target, task_path)

    assert {:error, {:write_failed, ^task_path, :eexist}} = Scaffold.init(dir, false)
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(task_path)
    refute File.exists?(target)
  end

  test "removes only files created before a later exclusive-create conflict", %{dir: dir} do
    task_path = Path.join(dir, "mytask.pkl")
    schema_path = Path.join(dir, "EcsSchema.pkl")
    symlink_target = Path.join(dir, "outside-schema.pkl")
    File.ln_s!(symlink_target, schema_path)

    assert {:error, {:write_failed, ^schema_path, :eexist}} = Scaffold.init(dir, true)
    refute File.exists?(task_path)
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(schema_path)
    refute File.exists?(symlink_target)
  end

  test "a missing target directory is created", %{dir: dir} do
    nested = Path.join([dir, "a", "b"])
    assert {:ok, [task_path]} = Scaffold.init(nested, false)
    assert File.exists?(task_path)
  end

  test "an unwritable target maps to {:write_failed, path, reason}", %{dir: dir} do
    blocker = Path.join(dir, "blocked")
    # a FILE where the target dir should be -> mkdir_p fails with :eexist/:enotdir
    File.write!(blocker, "i am a file")
    assert {:error, {:write_failed, ^blocker, reason}} = Scaffold.init(blocker, false)
    assert is_atom(reason)
  end

  test "a read-only target dir maps a File.write failure to {:write_failed, path, :eacces}", %{
    dir: dir
  } do
    # the dir already exists, so mkdir_p succeeds; only the subsequent
    # File.write of mytask.pkl inside it fails, exercising the write_all/1
    # error branch (as opposed to the mkdir_p failure above).
    locked = Path.join(dir, "locked")
    File.mkdir_p!(locked)
    File.chmod!(locked, 0o500)
    on_exit(fn -> File.chmod(locked, 0o700) end)

    task_path = Path.join(locked, "mytask.pkl")
    assert {:error, {:write_failed, ^task_path, :eacces}} = Scaffold.init(locked, false)
  end
end
