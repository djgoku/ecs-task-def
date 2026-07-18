defmodule EcsTaskDef.Validator do
  @moduledoc """
  Validates decoded task-definition JSON against the embedded awslabs schema.

  The pristine schema lives in priv/schema.json. At load time, patterns
  containing Unicode property escapes (\\p{...}) get a `(*UTF)(*UCP)` prefix:
  ex_json_schema compiles patterns without Unicode mode, and these PCRE
  start-of-pattern verbs re-enable it (spike-proven, see design spec
  "Resolved risk").
  """

  alias EcsTaskDef.SchemaPin

  @doc "Validate a decoded JSON value. :ok | {:error, [formatted_line]}"
  def validate(doc) do
    case ExJsonSchema.Validator.validate(resolved_schema(), doc) do
      :ok -> :ok
      {:error, errors} -> {:error, Enum.map(errors, &format_error/1)}
    end
  end

  @doc "The schema's own version string, e.g. \"v1.4.0\", parsed from its description."
  def schema_version do
    case Regex.run(~r/version (v\d+\.\d+\.\d+)/, raw_schema()["description"] || "") do
      [_, version] -> version
      nil -> "unknown"
    end
  end

  @doc false
  def preprocess_patterns(map) when is_map(map) do
    Map.new(map, fn
      {"pattern", pattern} when is_binary(pattern) ->
        if String.contains?(pattern, "\\p{") do
          {"pattern", "(*UTF)(*UCP)" <> pattern}
        else
          {"pattern", pattern}
        end

      {key, value} ->
        {key, preprocess_patterns(value)}
    end)
  end

  def preprocess_patterns(list) when is_list(list), do: Enum.map(list, &preprocess_patterns/1)
  def preprocess_patterns(other), do: other

  defp format_error({message, path}) do
    "#{friendly_path(path)}: #{message}"
  end

  # "#/containerDefinitions/0/cpu" -> "containerDefinitions[0].cpu"
  defp friendly_path("#"), do: "(document root)"

  defp friendly_path("#" <> rest) do
    rest
    |> String.split("/", trim: true)
    |> Enum.map_join("", fn segment ->
      case Integer.parse(segment) do
        {index, ""} -> "[#{index}]"
        _ -> "." <> segment
      end
    end)
    |> String.trim_leading(".")
  end

  defp raw_schema do
    fetch_cached({__MODULE__, :raw}, fn ->
      SchemaPin.schema_path() |> File.read!() |> JSON.decode!()
    end)
  end

  defp resolved_schema do
    fetch_cached({__MODULE__, :resolved}, fn ->
      raw_schema() |> preprocess_patterns() |> ExJsonSchema.Schema.resolve()
    end)
  end

  defp fetch_cached(key, fun) do
    case :persistent_term.get(key, nil) do
      nil ->
        value = fun.()
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end
end
