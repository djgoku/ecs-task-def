defmodule EcsTaskDef.ValidatorTest do
  use ExUnit.Case, async: true

  alias EcsTaskDef.Validator

  @valid %{
    "family" => "web-app",
    "containerDefinitions" => [%{"name" => "web", "image" => "nginx:latest"}]
  }

  test "a minimal valid task definition passes" do
    assert :ok = Validator.validate(@valid)
  end

  test "all violations are collected with friendly paths" do
    assert {:error, lines} = Validator.validate(%{"cpu" => 256})
    joined = Enum.join(lines, "\n")
    assert joined =~ "cpu: Type mismatch. Expected String but got Integer."
    assert joined =~ "family"
    assert joined =~ "containerDefinitions"
  end

  test "nested paths render as containerDefinitions[0].field" do
    doc = put_in(@valid, ["containerDefinitions"], [%{"name" => "web", "image" => 5}])
    assert {:error, [line]} = Validator.validate(doc)
    assert line =~ "containerDefinitions[0].image:"
  end

  test "non-ASCII letters in tag keys are accepted (Unicode pattern fix)" do
    doc = Map.put(@valid, "tags", [%{"key" => "Ünïcode-Key_1", "value" => "ok"}])
    assert :ok = Validator.validate(doc)
  end

  test "genuinely illegal tag keys still fail the pattern" do
    doc = Map.put(@valid, "tags", [%{"key" => "bad!key", "value" => "ok"}])
    assert {:error, [line]} = Validator.validate(doc)
    assert line =~ "tags[0].key:"
  end

  test "preprocess_patterns prefixes only \\p{}-patterns" do
    schema = %{
      "a" => %{"pattern" => "^[a-z]+$"},
      "b" => %{"pattern" => "^([\\p{L}]*)$"},
      "list" => [%{"pattern" => "^([\\p{N}]*)$"}]
    }

    out = Validator.preprocess_patterns(schema)
    assert out["a"]["pattern"] == "^[a-z]+$"
    assert out["b"]["pattern"] == "(*UTF)(*UCP)^([\\p{L}]*)$"
    assert hd(out["list"])["pattern"] == "(*UTF)(*UCP)^([\\p{N}]*)$"
  end

  test "schema_version parses the version from the schema description" do
    assert Validator.schema_version() =~ ~r/^v\d+\.\d+\.\d+$/
  end

  test "non-object JSON values are rejected with a root type violation, not a crash" do
    for doc <- [nil, [], 5, "x"] do
      assert {:error, [line]} = Validator.validate(doc)
      assert line =~ "Type mismatch. Expected Object but got"
    end
  end
end
