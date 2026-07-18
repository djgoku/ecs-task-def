defmodule EcsTaskDef.Scaffold do
  @moduledoc """
  `init` scaffolding. Writes a starter mytask.pkl (and, when vendor? is true,
  the embedded EcsSchema.pkl). Never overwrites: any pre-existing target
  aborts the whole scaffold before anything is written. A missing target
  directory is created; OS-level write failures surface as
  {:write_failed, path, reason}.
  """

  @package_base "package://pkg.pkl-lang.org/github.com/djgoku/aws-ecs-task-definition-generator/ecs-task-def"

  def init(dir, vendor?) do
    files = files(dir, vendor?)
    existing = for {path, _} <- files, File.exists?(path), do: path

    cond do
      existing != [] ->
        {:error, {:exists, existing}}

      true ->
        case File.mkdir_p(dir) do
          :ok -> write_all(files)
          {:error, reason} -> {:error, {:write_failed, dir, reason}}
        end
    end
  end

  defp write_all(files) do
    Enum.reduce_while(files, {:ok, []}, fn {path, contents}, {:ok, written} ->
      case File.write(path, contents) do
        :ok -> {:cont, {:ok, written ++ [path]}}
        {:error, reason} -> {:halt, {:error, {:write_failed, path, reason}}}
      end
    end)
  end

  defp files(dir, false) do
    [{Path.join(dir, "mytask.pkl"), render_starter(package_amends())}]
  end

  defp files(dir, true) do
    [
      {Path.join(dir, "mytask.pkl"), render_starter(~s(amends "EcsSchema.pkl"))},
      {Path.join(dir, "EcsSchema.pkl"), File.read!(priv_path("EcsSchema.pkl"))}
    ]
  end

  defp render_starter(amends_line) do
    priv_path("templates/starter.pkl.eex")
    |> File.read!()
    |> EEx.eval_string(assigns: [amends_line: amends_line])
  end

  defp package_amends do
    version = Application.spec(:ecs_task_def, :vsn) |> to_string()
    ~s(amends "#{@package_base}@#{version}#/EcsSchema.pkl")
  end

  defp priv_path(rel), do: Path.join(:code.priv_dir(:ecs_task_def), rel)
end
