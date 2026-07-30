defmodule Mix.Tasks.Compile.EcsSchema do
  use Mix.Task.Compiler

  @recursive true

  @impl true
  def run(_args) do
    project_root = File.cwd!()
    source = Path.join(project_root, "pkl/EcsSchema.pkl")
    source_priv = Path.join(project_root, "priv")
    build_priv = Path.join(Mix.Project.app_path(), "priv")
    destination = Path.join(build_priv, "EcsSchema.pkl")

    unless File.regular?(source) do
      Mix.raise("cannot copy ECS schema: #{source} is not a regular file")
    end

    File.rm_rf!(build_priv)
    File.cp_r!(source_priv, build_priv)
    File.cp!(source, destination)

    {:ok, []}
  end
end

defmodule EcsTaskDef.MixProject do
  use Mix.Project

  def project do
    [
      app: :ecs_task_def,
      version: "0.1.3",
      elixir: "~> 1.20",
      compilers: [:ecs_schema] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {EcsTaskDef.Application, []}
    ]
  end

  defp deps do
    [
      {:ex_json_schema, "~> 0.11.5"},
      {:nimble_options, "~> 1.1"},
      # NOT runtime: false — Burrito.Util.Args is called at runtime by
      # EcsTaskDef.Application, and runtime: false deps are excluded from
      # releases, which would crash the shipped binary.
      {:burrito, "~> 1.6"}
    ]
  end

  defp releases do
    [
      ecs_task_def: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: burrito_targets()
        ]
      ]
    ]
  end

  @all_burrito_targets [
    macos_aarch64: [os: :darwin, cpu: :aarch64],
    macos_x86_64: [os: :darwin, cpu: :x86_64],
    linux_x86_64: [os: :linux, cpu: :x86_64],
    linux_aarch64: [os: :linux, cpu: :aarch64]
  ]

  # Burrito's own BURRITO_TARGET override only accepts a single target
  # alias (deps/burrito/lib/builder/builder.ex does String.to_existing_atom/1
  # on the whole value), not the comma-separated list its README describes —
  # so it can't select "both CPU architectures for this OS" in one release
  # job. ECS_TASK_DEF_RELEASE_OS is our own narrower selector for that: the
  # release workflow's Linux job builds both linux targets in one `mix
  # release` by setting it to "linux", and the macOS job builds both macos
  # targets by setting it to "macos". Unset (local dev, `mix test`, etc.)
  # keeps building all four targets.
  defp burrito_targets do
    case System.get_env("ECS_TASK_DEF_RELEASE_OS") do
      nil ->
        @all_burrito_targets

      "linux" ->
        Keyword.take(@all_burrito_targets, [:linux_x86_64, :linux_aarch64])

      "macos" ->
        Keyword.take(@all_burrito_targets, [:macos_aarch64, :macos_x86_64])

      other ->
        Mix.raise(
          "ECS_TASK_DEF_RELEASE_OS must be \"linux\", \"macos\", or unset; got #{inspect(other)}"
        )
    end
  end
end
