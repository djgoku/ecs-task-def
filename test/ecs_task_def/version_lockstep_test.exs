defmodule EcsTaskDef.VersionLockstepTest do
  use ExUnit.Case, async: true

  test "pkl/PklProject version matches the mix project version" do
    mix_version = Application.spec(:ecs_task_def, :vsn) |> to_string()

    pkl_project = File.read!(Path.expand("../../pkl/PklProject", __DIR__))
    [_, pkl_version] = Regex.run(~r/version = "([^"]+)"/, pkl_project)

    assert pkl_version == mix_version,
           "pkl/PklProject version (#{pkl_version}) must match mix.exs (#{mix_version}); " <>
             "bump both together when releasing"
  end
end
