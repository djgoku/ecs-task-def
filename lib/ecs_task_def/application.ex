defmodule EcsTaskDef.Application do
  @moduledoc false
  use Application

  # In prod (the Burrito binary) the app boot IS the CLI run. In dev/test the
  # supervisor starts empty so `mix test` / `iex -S mix` behave normally.
  @impl true
  def start(_type, _args) do
    if Application.get_env(:ecs_task_def, :start_cli, false) do
      argv = burrito_argv()
      code = EcsTaskDef.CLI.run(argv)
      System.halt(code)
    end

    Supervisor.start_link([], strategy: :one_for_one, name: EcsTaskDef.Supervisor)
  end

  defp burrito_argv do
    Burrito.Util.Args.argv()
  end
end
