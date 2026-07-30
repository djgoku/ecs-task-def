defmodule Mix.Tasks.Ecs.RegenSchemaTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ecs.RegenSchema

  @schema_file "/tmp/ecs-regen-123/ecs-schema.json"
  @source_uri "file://#{@schema_file}"
  @raw_url "https://example.test/schema.json"

  test "formats generated Pkl before drift comparison" do
    path =
      Path.join(
        System.tmp_dir!(),
        "ecs-regen-format-#{System.unique_integer([:positive])}.pkl"
      )

    on_exit(fn -> File.rm(path) end)
    File.write!(path, ~s[value: ("a"|"b")\n])

    assert :ok = RegenSchema.format_generated!(path)
    assert File.read!(path) == ~s[value: ("a" | "b")\n]
  end

  test "normalizes wrapped and unwrapped generated source comments identically" do
    canonical = """
    /// Header.
    /// This module was generated from JSON Schema from
    /// <#{@raw_url}>.
    module EcsSchema
    """

    for source_comment <- [
          "/// This module was generated from JSON Schema from <#{@source_uri}>.",
          "/// This module was generated from JSON Schema from\n/// <#{@source_uri}>."
        ] do
      generated = """
      /// Header.
      #{source_comment}
      module EcsSchema
      """

      assert RegenSchema.normalize_source_comment(generated, @schema_file, @raw_url) ==
               canonical
    end
  end
end
