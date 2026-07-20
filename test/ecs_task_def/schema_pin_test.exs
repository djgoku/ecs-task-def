defmodule EcsTaskDef.SchemaPinTest do
  use ExUnit.Case, async: true

  test "pin is a full 40-char commit SHA" do
    assert EcsTaskDef.SchemaPin.sha() =~ ~r/^[0-9a-f]{40}$/
  end

  test "short sha is the first 7 chars" do
    assert EcsTaskDef.SchemaPin.short_sha() == String.slice(EcsTaskDef.SchemaPin.sha(), 0, 7)
  end

  test "vendored schema exists, parses, and carries a version in its description" do
    raw = EcsTaskDef.SchemaPin.schema_path() |> File.read!() |> JSON.decode!()
    assert raw["$schema"] == "http://json-schema.org/draft-07/schema#"
    assert Regex.match?(~r/version v\d+\.\d+\.\d+/, raw["description"])
  end
end
