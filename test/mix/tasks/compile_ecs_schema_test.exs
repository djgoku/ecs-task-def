defmodule Mix.Tasks.Compile.EcsSchemaTest do
  use ExUnit.Case

  @repo_root Path.expand("../../..", __DIR__)

  test "rebuilds application priv exactly and copies the canonical Pkl schema" do
    source = Path.join(@repo_root, "pkl/EcsSchema.pkl")
    committed_priv_copy = Path.join(@repo_root, "priv/EcsSchema.pkl")
    build_priv = :code.priv_dir(:ecs_task_def) |> to_string()
    built_priv_copy = Path.join(build_priv, "EcsSchema.pkl")
    stale_build_file = Path.join(build_priv, "stale")

    File.write!(stale_build_file, "remove me")

    assert {:ok, []} = Mix.Tasks.Compile.EcsSchema.run([])
    refute File.exists?(committed_priv_copy)
    refute File.exists?(stale_build_file)
    assert File.read!(built_priv_copy) == File.read!(source)
  end
end
