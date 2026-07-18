defmodule EcsTaskDef.MixProject do
  use Mix.Project

  def project do
    [
      app: :ecs_task_def,
      version: "0.1.0",
      elixir: "~> 1.20",
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
      {:burrito, "~> 1.5"}
    ]
  end

  defp releases do
    [
      ecs_task_def: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_aarch64: [os: :darwin, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64],
            linux_x86_64: [os: :linux, cpu: :x86_64],
            linux_aarch64: [os: :linux, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end
end
