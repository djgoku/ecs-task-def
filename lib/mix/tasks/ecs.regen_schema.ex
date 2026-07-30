defmodule Mix.Tasks.Ecs.RegenSchema do
  @shortdoc "Regenerate priv/schema.json and pkl/EcsSchema.pkl from the pinned awslabs schema"

  @moduledoc """
  Downloads the awslabs amazon-ecs-intellisense-schema at the commit pinned in
  EcsTaskDef.SchemaPin, regenerates the typed Pkl module with the official
  pkl-pantry codegen, and refreshes both committed artifacts together:

    * priv/schema.json    (pristine copy, embedded for the validator)
    * pkl/EcsSchema.pkl   (published as a Pkl package and copied into `priv`
      at build time for `init --vendor`)

  Requires network access, curl, and pkl on PATH. Dev/CI-time only.

      mix ecs.regen_schema           # regenerate in place
      mix ecs.regen_schema --check   # regenerate to a temp dir and fail on diff (CI)
  """

  use Mix.Task

  @codegen "package://pkg.pkl-lang.org/pkl-pantry/org.json_schema.contrib@1.2.0#/generate.pkl"

  @impl true
  def run(args) do
    check? = "--check" in args
    tmp = Path.join(System.tmp_dir!(), "ecs-regen-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      # File must be named ecs-schema.json: the codegen derives the module name
      # (EcsSchema) by pascal-casing the source basename.
      raw_url = EcsTaskDef.SchemaPin.raw_url()
      schema_file = Path.join(tmp, "ecs-schema.json")
      download!(raw_url, schema_file)

      outdir = Path.join(tmp, "generated")

      {output, code} =
        System.cmd(
          "pkl",
          ["eval", @codegen, "-m", outdir, "-p", "source=#{schema_file}"],
          stderr_to_stdout: true
        )

      if code != 0, do: Mix.raise("pkl codegen failed (exit #{code}):\n#{output}")

      generated = Path.join(outdir, "EcsSchema.pkl")

      unless File.exists?(generated) do
        Mix.raise("codegen did not produce EcsSchema.pkl; produced: #{inspect(File.ls!(outdir))}")
      end

      format_generated!(generated)

      # The codegen embeds the absolute local path of the source file (which
      # varies run to run, since it lives under a fresh temp dir) into the
      # generated doc comment. Rewrite it to the stable pinned upstream URL so
      # the committed artifact is reproducible and `--check` is meaningful.
      generated_contents =
        generated
        |> File.read!()
        |> normalize_source_comment(schema_file, raw_url)

      targets = %{
        "priv/schema.json" => File.read!(schema_file),
        "pkl/EcsSchema.pkl" => generated_contents
      }

      if check?, do: check!(targets), else: write!(targets)
    after
      File.rm_rf(tmp)
    end
  end

  defp write!(targets) do
    for {path, contents} <- targets do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
      Mix.shell().info("wrote #{path}")
    end
  end

  defp check!(targets) do
    stale =
      for {path, contents} <- targets,
          not File.exists?(path) or File.read!(path) != contents,
          do: path

    if stale == [] do
      Mix.shell().info("regen check: all artifacts up to date")
    else
      Mix.raise(
        "regen check FAILED — stale artifacts: #{Enum.join(stale, ", ")}. " <>
          "Run `mix ecs.regen_schema` and commit the result."
      )
    end
  end

  defp download!(url, dest) do
    {_, code} = System.cmd("curl", ["-fsSL", url, "-o", dest], stderr_to_stdout: true)
    if code != 0, do: Mix.raise("failed to download #{url} (curl exit #{code})")
  end

  @doc false
  def format_generated!(path) do
    {output, code} =
      System.cmd("pkl", ["format", "-w", path], stderr_to_stdout: true)

    if code != 0 do
      Mix.raise("pkl format failed (exit #{code}):\n#{output}")
    end

    :ok
  end

  @doc false
  def normalize_source_comment(contents, schema_file, raw_url) do
    source_uri = "file://" <> schema_file

    canonical =
      "/// This module was generated from JSON Schema from\n" <>
        "/// <#{raw_url}>."

    contents
    |> String.replace(
      "/// This module was generated from JSON Schema from <#{source_uri}>.",
      canonical
    )
    |> String.replace(
      "/// This module was generated from JSON Schema from\n/// <#{source_uri}>.",
      canonical
    )
  end
end
