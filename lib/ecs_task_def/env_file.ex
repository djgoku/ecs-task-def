defmodule EcsTaskDef.EnvFile do
  @moduledoc """
  Parses the deliberately small .env grammar from the design spec, and merges
  the result under the process environment (process env wins).
  """

  @key_re ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @doc "Parse a .env file. {:ok, map, warnings} | {:error, message}"
  def parse(path) do
    case File.read(path) do
      {:error, reason} ->
        {:error, "#{path}: cannot read env file (#{:file.format_error(reason)})"}

      {:ok, contents} ->
        contents
        |> String.replace_prefix("﻿", "")
        |> String.split("\n")
        |> Enum.map(&String.replace_suffix(&1, "\r", ""))
        |> Enum.with_index(1)
        |> parse_lines(path)
    end
  end

  defp parse_lines(lines, path) do
    Enum.reduce_while(lines, {:ok, %{}, [], %{}}, fn {line, no}, {:ok, acc, warns, seen} ->
      case classify(line) do
        :skip ->
          {:cont, {:ok, acc, warns, seen}}

        {:pair, key, value} ->
          warns =
            case seen do
              %{^key => prev_no} ->
                warns ++
                  [
                    "#{path}: duplicate key #{key} on lines #{prev_no} and #{no}; using line #{no}"
                  ]

              _ ->
                warns
            end

          {:cont, {:ok, Map.put(acc, key, value), warns, Map.put(seen, key, no)}}

        {:error, reason} ->
          {:halt, {:error, "#{path}:#{no}: #{reason}"}}
      end
    end)
    |> case do
      {:ok, map, warns, _seen} -> {:ok, map, warns}
      {:error, _} = err -> err
    end
  end

  defp classify(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" -> :skip
      String.starts_with?(trimmed, "#") -> :skip
      not String.contains?(trimmed, "=") -> {:error, "expected KEY=VALUE (no '=' found)"}
      true -> split_pair(trimmed)
    end
  end

  defp split_pair(trimmed) do
    [raw_key, raw_value] = String.split(trimmed, "=", parts: 2)
    key = raw_key |> String.trim() |> String.replace_prefix("export ", "") |> String.trim()

    if Regex.match?(@key_re, key) do
      {:pair, key, raw_value |> String.trim() |> strip_quotes()}
    else
      {:error, "invalid key #{inspect(key)} (must match [A-Za-z_][A-Za-z0-9_]*)"}
    end
  end

  defp strip_quotes(<<q, rest::binary>> = value) when q in [?", ?'] do
    if byte_size(rest) >= 1 and :binary.last(rest) == q do
      binary_part(rest, 0, byte_size(rest) - 1)
    else
      value
    end
  end

  defp strip_quotes(value), do: value

  @doc """
  Merge a parsed env-file map under the process environment.

  Returns `{extra, shadow_warnings}` where `extra` is the list of {key, value}
  pairs to append to the spawned process's environment (only keys the process
  environment does not already define — process env wins), and
  `shadow_warnings` describe keys defined on both sides with different values
  (values are never included in the message).
  """
  def merge(file_map, sys_env, env_file_path) do
    extra =
      file_map
      |> Enum.reject(fn {k, _v} -> Map.has_key?(sys_env, k) end)
      |> Enum.sort()

    warnings =
      for {k, v} <- Enum.sort(file_map),
          Map.has_key?(sys_env, k),
          Map.fetch!(sys_env, k) != v do
        "warning: #{k} is set in both the environment and #{env_file_path} " <>
          "with different values; using the environment value"
      end

    {extra, warnings}
  end
end
