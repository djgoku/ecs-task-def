defmodule EcsTaskDef.Integration.CorpusTest do
  use ExUnit.Case

  @moduletag :pkl

  @corpus_dir Path.expand("../fixtures/corpus", __DIR__)

  # Pkl's JSON renderer omits any property whose value is null, whether the
  # property was left unset or assigned `null` explicitly (verified: neither
  # form is distinguishable in `pkl eval -f json` output). One upstream
  # fixture (wildfly_fargate, straight from aws-samples) contains a redundant
  # `"ulimits": null` key that a schema-conformant Pkl port can never
  # reproduce byte-for-key, since the same toggle that would preserve it
  # (`omitNullProperties = false`) would also surface every other unset
  # field in the document as an explicit null. Dropping null-valued keys
  # before comparing reflects that documented Pkl semantic rather than
  # patching around one fixture; it is applied uniformly to every pair.
  defp drop_nulls(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {k, drop_nulls(v)} end)
  end

  defp drop_nulls(list) when is_list(list), do: Enum.map(list, &drop_nulls/1)
  defp drop_nulls(other), do: other

  for pkl_file <- Path.wildcard(Path.join(Path.expand("../fixtures/corpus", __DIR__), "*.pkl")) do
    name = Path.basename(pkl_file, ".pkl")

    test "corpus fixture #{name} matches its AWS-authored golden JSON and validates" do
      pkl_file = Path.join(@corpus_dir, "#{unquote(name)}.pkl")
      golden_file = Path.join(@corpus_dir, "#{unquote(name)}.golden.json")

      pkl = System.find_executable("pkl")
      assert {:ok, out, _stderr} = EcsTaskDef.Pkl.eval(pkl, pkl_file, [])

      generated = JSON.decode!(out)
      golden = golden_file |> File.read!() |> JSON.decode!()

      assert drop_nulls(generated) == drop_nulls(golden)
      assert :ok = EcsTaskDef.Validator.validate(generated)
      assert :ok = EcsTaskDef.Validator.validate(drop_nulls(golden))
    end
  end

  test "negative fixture pr512_invalid is rejected by the validator" do
    doc =
      Path.expand("../fixtures/negative/pr512_invalid.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()

    assert {:error, lines} = EcsTaskDef.Validator.validate(doc)
    assert lines != []
  end
end
