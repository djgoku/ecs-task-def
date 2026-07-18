defmodule EcsTaskDef.Pkl do
  @moduledoc """
  Spawns `pkl eval -f json INPUT` with the merged environment and captures
  stdout (the JSON) and stderr (diagnostics) separately.

  Erlang ports cannot capture a child's stderr separately, so the child runs
  under `/bin/sh -c 'exec "$0" "$@" 2>"$FILE"'` with stderr redirected to a
  temp file (macOS/Linux only, which matches the supported platforms).
  """

  def eval(pkl_path, input_path, extra_env) do
    stderr_file =
      Path.join(
        System.tmp_dir!(),
        "ecs-task-def-stderr-#{System.unique_integer([:positive])}"
      )

    try do
      {stdout, exit_code} =
        System.cmd(
          "/bin/sh",
          ["-c", ~S(exec "$0" "$@" 2>"$ECS_TASK_DEF_STDERR_FILE"), pkl_path, "eval", "-f", "json", input_path],
          env: [{"ECS_TASK_DEF_STDERR_FILE", stderr_file} | extra_env]
        )

      stderr =
        case File.read(stderr_file) do
          {:ok, contents} -> contents
          {:error, _} -> ""
        end

      if exit_code == 0 do
        {:ok, stdout, stderr}
      else
        {:error, {exit_code, stderr}}
      end
    after
      File.rm(stderr_file)
    end
  end
end
