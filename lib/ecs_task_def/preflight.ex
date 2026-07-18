defmodule EcsTaskDef.Preflight do
  @moduledoc """
  Finds the pkl CLI on PATH and enforces the minimum version the schema and
  codegen are tested against. Runs before anything else so failures are early
  and actionable.
  """

  @minimum "0.31.1"

  def minimum_version, do: @minimum

  @doc "check(env) :: {:ok, pkl_path, version} | {:error, message}"
  def check(env \\ System.get_env()) do
    path_var = Map.get(env, "PATH", "")

    case find_executable("pkl", path_var) do
      nil ->
        {:error,
         "pkl not found on PATH. Install it with `brew install pkl` or " <>
           "`mise use pkl@latest` (version #{@minimum} or newer required), then re-run."}

      pkl_path ->
        check_version(pkl_path, env)
    end
  end

  defp check_version(pkl_path, env) do
    {output, 0} =
      System.cmd(pkl_path, ["--version"], env: extra_env(env), stderr_to_stdout: true)

    case Regex.run(~r/Pkl (\d+\.\d+\.\d+)/, output) do
      [_, version] ->
        if Version.compare(version, @minimum) == :lt do
          {:error,
           "pkl #{version} is too old; ecs-task-def needs #{@minimum} or newer. " <>
             "Upgrade with `brew upgrade pkl` or `mise use pkl@latest`."}
        else
          {:ok, pkl_path, version}
        end

      nil ->
        {:error, "could not parse `pkl --version` output: #{inspect(String.trim(output))}"}
    end
  rescue
    e in [ErlangError, MatchError] ->
      {:error, "failed to run `#{pkl_path} --version`: #{Exception.message(e)}"}
  end

  # System.find_executable/1 only consults the real process PATH; this variant
  # honors an injected env for testability.
  defp find_executable(name, path_var) do
    path_var
    |> String.split(":", trim: true)
    |> Enum.map(&Path.join(&1, name))
    |> Enum.find(&executable?/1)
  end

  defp executable?(candidate) do
    case File.stat(candidate) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  # Pass FAKE_PKL_* through for the test fixture; harmless in production.
  defp extra_env(env) do
    for {k, v} <- env, String.starts_with?(k, "FAKE_PKL_"), do: {k, v}
  end
end
