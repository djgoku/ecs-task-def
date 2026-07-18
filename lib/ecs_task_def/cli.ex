defmodule EcsTaskDef.CLI do
  @moduledoc """
  argv → exit code. All human output goes to stderr; the generated JSON is the
  only thing written to stdout (when --output is not given).

  Environment semantics of run/2: the env map is consulted for PATH lookup and
  for merge/shadow decisions against the --env-file. The spawned pkl child
  always inherits the REAL process environment plus the env-file extras —
  so tests that need a variable visible to pkl must System.put_env it (see
  Task 12 integration tests), not merely pass it in the map.
  """

  alias EcsTaskDef.{EnvFile, Output, Pkl, Preflight, Scaffold, SchemaPin, Validator}

  @generate_opts NimbleOptions.new!(
                   output: [type: :string, doc: "Write the JSON here instead of stdout."],
                   env_file: [
                     type: :string,
                     doc: "KEY=VALUE defaults merged under the process environment."
                   ]
                 )

  @init_opts NimbleOptions.new!(
               vendor: [
                 type: :boolean,
                 default: false,
                 doc:
                   "Vendor EcsSchema.pkl into the target directory; amends points at the local file."
               ]
             )

  @known_flags ~w(--output -o --env-file --vendor --help -h)

  def run(argv), do: run(argv, System.get_env())

  def run(argv, env) do
    case argv do
      ["generate" | rest] -> generate(rest, env)
      ["init" | rest] -> init(rest, env)
      ["--help"] -> usage(:stdio)
      ["-h"] -> usage(:stdio)
      [] -> usage_error("missing command")
      [other | _] -> usage_error("unknown command #{inspect(other)}")
    end
  end

  # -- generate ---------------------------------------------------------------

  defp generate(args, env) do
    with {:ok, input, opts} <-
           parse(args, @generate_opts, [output: :string, env_file: :string], [o: :output], 1),
         {:ok, pkl_path, pkl_version} <- stage_preflight(env),
         {:ok, extra_env} <- stage_env(opts[:env_file], env),
         {:ok, json_text} <- stage_eval(pkl_path, pkl_version, input, extra_env),
         {:ok, _doc} <- stage_validate(json_text),
         :ok <- stage_write(opts[:output], json_text) do
      0
    else
      {:exit, code} -> code
    end
  end

  defp stage_preflight(env) do
    case Preflight.check(env) do
      {:ok, path, version} ->
        info("✓ pkl #{version} found")
        {:ok, path, version}

      {:error, message} ->
        error(message)
        {:exit, 2}
    end
  end

  defp stage_env(nil, _env), do: {:ok, []}

  defp stage_env(env_file, env) do
    case EnvFile.parse(env_file) do
      {:ok, map, warnings} ->
        Enum.each(warnings, &info/1)
        {extra, shadow_warnings} = EnvFile.merge(map, env, env_file)
        Enum.each(shadow_warnings, &info/1)
        {:ok, extra}

      {:error, message} ->
        error(message)
        {:exit, 3}
    end
  end

  defp stage_eval(pkl_path, _pkl_version, input, extra_env) do
    case Pkl.eval(pkl_path, input, extra_env) do
      {:ok, stdout, stderr} ->
        if stderr != "", do: IO.write(:stderr, stderr)
        info("✓ evaluated #{input}")
        {:ok, stdout}

      {:error, {code, stderr}} ->
        error("pkl eval failed for #{input} (exit #{code}):")
        IO.write(:stderr, stderr)
        {:exit, 4}
    end
  end

  defp stage_validate(json_text) do
    doc =
      try do
        JSON.decode!(json_text)
      rescue
        _ ->
          error("pkl produced output that is not valid JSON (this is a bug — please report it)")
          throw(:invalid_json)
      end

    case Validator.validate(doc) do
      :ok ->
        info(
          "✓ validated against ECS schema #{Validator.schema_version()} (awslabs@#{SchemaPin.short_sha()})"
        )

        {:ok, doc}

      {:error, lines} ->
        error("schema validation failed with #{length(lines)} violation(s):")
        Enum.each(lines, fn line -> IO.puts(:stderr, "  " <> line) end)
        {:exit, 5}
    end
  catch
    :invalid_json -> {:exit, 4}
  end

  defp stage_write(nil, json_text) do
    IO.write(json_text)
    :ok
  end

  defp stage_write(path, json_text) do
    case Output.write(path, json_text) do
      :ok ->
        info("wrote #{path}")
        :ok

      {:error, message} ->
        error(message)
        {:exit, 6}
    end
  end

  # -- init -------------------------------------------------------------------

  defp init(args, _env) do
    with {:ok, dir, opts} <- parse(args, @init_opts, [vendor: :boolean], [], {0, 1}) do
      dir = dir || "."

      case Scaffold.init(dir, opts[:vendor]) do
        {:ok, paths} ->
          Enum.each(paths, fn p -> info("created #{p}") end)

          info(
            "next: set your env vars and run `ecs-task-def generate #{Path.join(dir, "mytask.pkl")}`"
          )

          0

        {:error, {:exists, paths}} ->
          error("refusing to overwrite; these files already exist:")
          Enum.each(paths, fn p -> IO.puts(:stderr, "  " <> p) end)
          error("move them aside or run init in an empty directory")
          6

        {:error, {:write_failed, path, reason}} ->
          error("cannot write #{path}: #{:file.format_error(reason)}")
          6
      end
    else
      {:exit, code} -> code
    end
  end

  # -- parsing ----------------------------------------------------------------

  # arity: 1 = exactly one positional; {0, 1} = zero or one positional
  defp parse(args, nimble_schema, strict, aliases, arity) do
    strict = Keyword.put(strict, :help, :boolean)
    aliases = Keyword.put(aliases, :h, :help)
    {opts, positional, invalid} = OptionParser.parse(args, strict: strict, aliases: aliases)

    cond do
      opts[:help] ->
        usage(:stdio)
        {:exit, 0}

      invalid != [] ->
        {flag, value} = hd(invalid)

        if value == nil and Map.get(option_types(strict, aliases), flag) == :string do
          usage_error_exit("option #{flag} requires a value")
        else
          usage_error_exit("unknown option #{flag}#{suggestion(flag)}")
        end

      arity == 1 and length(positional) != 1 ->
        usage_error_exit("expected exactly one INPUT.pkl argument, got #{length(positional)}")

      arity == {0, 1} and length(positional) > 1 ->
        usage_error_exit("expected at most one DIR argument, got #{length(positional)}")

      true ->
        case NimbleOptions.validate(Keyword.delete(opts, :help), nimble_schema) do
          {:ok, validated} ->
            {:ok, List.first(positional), validated}

          {:error, %NimbleOptions.ValidationError{} = e} ->
            usage_error_exit(Exception.message(e))
        end
    end
  end

  # Maps every known CLI spelling (long and short) for this command's parse
  # call to its NimbleOptions type, so a missing-value flag (nil value in
  # OptionParser's invalid list) can be told apart from a genuinely unknown
  # one — both shapes look identical to OptionParser itself.
  defp option_types(strict, aliases) do
    long =
      for {key, type} <- strict, into: %{} do
        {"--" <> (key |> Atom.to_string() |> String.replace("_", "-")), type}
      end

    short =
      for {short, key} <- aliases, type = Keyword.get(strict, key), into: %{} do
        {"-" <> Atom.to_string(short), type}
      end

    Map.merge(long, short)
  end

  defp suggestion(flag) do
    {best, distance} =
      @known_flags
      |> Enum.map(fn known -> {known, String.jaro_distance(flag, known)} end)
      |> Enum.max_by(fn {_, d} -> d end)

    if distance > 0.7, do: ", did you mean #{best}?", else: ""
  end

  # Spec exit-1 contract: usage errors always show usage + suggestion.
  defp usage_error_exit(message) do
    error(message)
    usage(:stderr)
    {:exit, 1}
  end

  defp usage_error(message) do
    error(message)
    usage(:stderr)
    1
  end

  defp usage(device) do
    version = Application.spec(:ecs_task_def, :vsn) |> to_string()

    IO.puts(device, """
    ecs-task-def #{version} — ECS schema #{Validator.schema_version()} (awslabs@#{SchemaPin.short_sha()})

    Usage:
      ecs-task-def generate INPUT.pkl [--output|-o PATH] [--env-file PATH]
      ecs-task-def init [DIR] [--vendor]

    generate options:
    #{option_docs(@generate_opts, o: :output, h: :help)}
    init options:
    #{option_docs(@init_opts, h: :help)}
    """)

    if device == :stdio, do: 0, else: 1
  end

  # NimbleOptions.docs/1 renders its own internal atom-key spellings (e.g.
  # `:env_file`), not the CLI's actual `--env-file` flag — validation still
  # goes through NimbleOptions, but the terminal help text is rendered from
  # the same schema by hand so users see real, pastable flags.
  @help_flag {:help, [type: :boolean, doc: "Show this help and exit."]}

  defp option_docs(nimble_opts, aliases) do
    short_by_long = for {short, long} <- aliases, into: %{}, do: {long, short}

    (nimble_opts.schema ++ [@help_flag])
    |> Enum.map_join("\n", &render_flag(&1, short_by_long))
  end

  defp render_flag({key, spec}, short_by_long) do
    long = "--" <> (key |> Atom.to_string() |> String.replace("_", "-"))

    spellings =
      case Map.fetch(short_by_long, key) do
        {:ok, short} -> "#{long}, -#{short}"
        :error -> long
      end

    spellings =
      if Keyword.get(spec, :type) == :boolean, do: spellings, else: spellings <> " VALUE"

    "  #{spellings}\n      #{Keyword.get(spec, :doc)}"
  end

  defp info(line), do: IO.puts(:stderr, line)
  defp error(line), do: IO.puts(:stderr, "error: " <> line)
end
