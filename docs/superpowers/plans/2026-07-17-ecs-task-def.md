# ecs-task-def Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `ecs-task-def`, an Elixir CLI (Burrito single binary) that evaluates a typed Pkl file into schema-validated ECS task-definition JSON, per `docs/superpowers/specs/2026-07-17-ecs-task-def-design.md`.

**Architecture:** Six small modules (`CLI`, `Preflight`, `EnvFile`, `Pkl`, `Validator`, `Scaffold`) plus `Output`, `SchemaPin`, and a `mix ecs.regen_schema` task. The `pkl` CLI (required on PATH) does evaluation; `ex_json_schema` validates against the embedded awslabs schema; `nimble_options` validates parsed CLI options.

**Tech Stack:** Elixir 1.20.1-otp-29 / Erlang 29.0.2 / pkl 0.31.1 (all via mise), `ex_json_schema ~> 0.11.5`, `nimble_options ~> 1.1`, `burrito ~> 1.5`, built-in `JSON` module (no jason).

**Conventions used throughout:**
- All commands run from the repo root unless stated.
- Every ExUnit test file starts `use ExUnit.Case, async: true` unless it manipulates global state (noted where not).
- Integration tests that need the real `pkl` binary are tagged `@tag :pkl`; `test_helper.exs` excludes the tag when `pkl` is absent.
- Exit codes (from the spec): 0 success, 1 usage, 2 pkl missing/old, 3 env file, 4 pkl eval, 5 schema validation, 6 write/init-exists.

**File map (final state):**

| Path | Responsibility |
|---|---|
| `mix.exs` | project, deps, Burrito release config |
| `config/config.exs`, `config/{dev,test,prod}.exs` | `:start_cli` gate (prod-only autostart) |
| `lib/ecs_task_def/application.ex` | Burrito entrypoint: argv → `CLI.run/1` → halt |
| `lib/ecs_task_def/cli.ex` | argv parsing (OptionParser + NimbleOptions), dispatch, output, exit codes |
| `lib/ecs_task_def/preflight.ex` | find `pkl`, minimum-version check |
| `lib/ecs_task_def/env_file.ex` | `.env` parse (spec grammar) + merge/shadow warnings |
| `lib/ecs_task_def/pkl.ex` | spawn `pkl eval -f json`, separate stdout/stderr |
| `lib/ecs_task_def/validator.ex` | load embedded schema, `(*UTF)(*UCP)` preprocessing, validate, friendly errors |
| `lib/ecs_task_def/output.ex` | atomic file write / stdout write |
| `lib/ecs_task_def/scaffold.ex` | `init` file generation, never-overwrite |
| `lib/ecs_task_def/schema_pin.ex` | single source of truth: pinned awslabs commit SHA |
| `lib/mix/tasks/ecs.regen_schema.ex` | regen `priv/schema.json` + `pkl/EcsSchema.pkl` (+ `--check`) |
| `priv/schema.json` | pristine pinned awslabs schema (embedded asset) |
| `priv/EcsSchema.pkl` | embedded copy of generated module (for `--vendor`) |
| `pkl/EcsSchema.pkl` | committed generated Pkl module (source of truth, packaged) |
| `pkl/PklProject` | Pkl package metadata for `pkl project package` |
| `test/…` | mirrors lib; plus `test/fixtures/`, `test/support/fake_pkl.sh` |
| `.github/workflows/ci.yml` | test matrix, drift check, check-jsonschema cross-check |
| `.github/workflows/release.yml` | Burrito binaries + Pkl package on `ecs-task-def@X.Y.Z` tags |
| `mise.toml`, `mise.lock` | pinned toolchain |

---

### Task 1: Project bootstrap (mise toolchain + mix project + deps)

**Files:**
- Create: `mise.toml`, `mix.exs` (via generator, then edit), `.gitignore`, `lib/ecs_task_def.ex`, `test/`, `config/config.exs`, `config/dev.exs`, `config/test.exs`, `config/prod.exs`

- [ ] **Step 1: Pin the toolchain with mise**

Create `mise.toml`:

```toml
[tools]
erlang = "29.0.2"
elixir = "1.20.1-otp-29"
pkl = "0.31.1"
zig = "0.15.2" # required by burrito at release-build time
```

Run: `mise install && mise ls --current`
Expected: all four tools listed as installed/active for this directory. A `mise.lock` file appears (commit it).

Note: zig 0.15.2 is the version Burrito 1.5.0 pins (see `~/.claude/knowledge-base/burrito-zig-macos26.md`). If `mise install` cannot provide zig 0.15.2, install it via `mise use zig@0.15.2` and record what the lockfile resolves.

- [ ] **Step 2: Generate the mix project in place**

Run: `mix new . --app ecs_task_def --module EcsTaskDef`
Expected: creates `mix.exs`, `lib/ecs_task_def.ex`, `test/ecs_task_def_test.exs`, `test/test_helper.exs`, `.formatter.exs`, `.gitignore` alongside the existing `docs/` and `.git/`. If mix refuses because the directory is non-empty, run `mix new /tmp/ecs_task_def_bootstrap --app ecs_task_def --module EcsTaskDef && cp -R /tmp/ecs_task_def_bootstrap/. .` (then delete `/tmp/ecs_task_def_bootstrap`).

- [ ] **Step 3: Configure mix.exs (deps, app mod, dialyzer-free minimal)**

Replace the generated `mix.exs` contents with:

```elixir
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
      {:burrito, "~> 1.5", runtime: false}
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
```

- [ ] **Step 4: Create the application module and the `:start_cli` gate**

Create `config/config.exs`:

```elixir
import Config
import_config "#{config_env()}.exs"
```

Create `config/dev.exs` and `config/test.exs` (identical content):

```elixir
import Config
config :ecs_task_def, start_cli: false
```

Create `config/prod.exs`:

```elixir
import Config
config :ecs_task_def, start_cli: true
```

Create `lib/ecs_task_def/application.ex`:

```elixir
defmodule EcsTaskDef.Application do
  @moduledoc false
  use Application

  # In prod (the Burrito binary) the app boot IS the CLI run. In dev/test the
  # supervisor starts empty so `mix test` / `iex -S mix` behave normally.
  @impl true
  def start(_type, _args) do
    if Application.get_env(:ecs_task_def, :start_cli, false) do
      argv = burrito_argv()
      code = EcsTaskDef.CLI.run(argv)
      System.halt(code)
    end

    Supervisor.start_link([], strategy: :one_for_one, name: EcsTaskDef.Supervisor)
  end

  defp burrito_argv do
    # Verified against the Burrito version in deps at implementation time:
    # grep -rn "def argv\|def get_arguments" deps/burrito/lib/burrito/util/args.ex
    # and use whichever public function exists there.
    Burrito.Util.Args.argv()
  end
end
```

Also create a placeholder so the project compiles before Task 11 (replaced there):

Create `lib/ecs_task_def/cli.ex`:

```elixir
defmodule EcsTaskDef.CLI do
  @moduledoc "Command-line interface. Implemented in Task 11."
  def run(_argv), do: 0
end
```

- [ ] **Step 5: Verify grep for the real Burrito argv function and fix `burrito_argv/0` if needed**

Run: `mix deps.get && grep -rn "def argv\|def get_arguments" deps/burrito/lib/burrito/util/args.ex`
Expected: one public function; make `burrito_argv/0` call exactly that one (edit if it is `get_arguments/0`).

- [ ] **Step 6: Compile and run the (empty) test suite**

Run: `mix compile --warnings-as-errors && mix test`
Expected: compiles clean; the generated doctest may fail — delete `test/ecs_task_def_test.exs`'s generated test and `lib/ecs_task_def.ex`'s example function, leaving:

`lib/ecs_task_def.ex`:

```elixir
defmodule EcsTaskDef do
  @moduledoc """
  ecs-task-def: generate validated ECS task-definition JSON from Pkl.
  """
end
```

and delete `test/ecs_task_def_test.exs`. Re-run `mix test` → `0 failures`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "chore: bootstrap mix project, mise toolchain, deps (ex_json_schema, nimble_options, burrito)"
```

---

### Task 2: SchemaPin + vendored pristine schema

**Files:**
- Create: `lib/ecs_task_def/schema_pin.ex`
- Create: `priv/schema.json` (downloaded)
- Test: `test/ecs_task_def/schema_pin_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/ecs_task_def/schema_pin_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/ecs_task_def/schema_pin_test.exs`
Expected: FAIL — `EcsTaskDef.SchemaPin` is undefined.

- [ ] **Step 3: Implement SchemaPin and download the schema**

Create `lib/ecs_task_def/schema_pin.ex`:

```elixir
defmodule EcsTaskDef.SchemaPin do
  @moduledoc """
  Single source of truth for the pinned awslabs amazon-ecs-intellisense-schema
  commit. `mix ecs.regen_schema` downloads from this SHA; the CLI displays it.
  Bumping the pin is an explicit edit of @sha followed by `mix ecs.regen_schema`.
  """

  @sha "39fae90314c74f897ba2a74549898542735e3628"

  def sha, do: @sha
  def short_sha, do: String.slice(@sha, 0, 7)

  def raw_url do
    "https://raw.githubusercontent.com/awslabs/amazon-ecs-intellisense-schema/#{@sha}/src/model/schema/schema.json"
  end

  def schema_path, do: Path.join(:code.priv_dir(:ecs_task_def), "schema.json")
end
```

Download the pinned schema:

Run: `mkdir -p priv && curl -fsSL "https://raw.githubusercontent.com/awslabs/amazon-ecs-intellisense-schema/39fae90314c74f897ba2a74549898542735e3628/src/model/schema/schema.json" -o priv/schema.json && head -c 200 priv/schema.json`
Expected: JSON beginning `{"$schema": "http://json-schema.org/draft-07/schema#"` (≈93 KB file).

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/ecs_task_def/schema_pin_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/ecs_task_def/schema_pin.ex priv/schema.json test/ecs_task_def/schema_pin_test.exs
git commit -m "feat: pin awslabs schema by commit SHA and vendor pristine schema.json"
```

---

### Task 3: EnvFile.parse — the .env grammar

**Files:**
- Create: `lib/ecs_task_def/env_file.ex`
- Test: `test/ecs_task_def/env_file_test.exs`

API contract: `parse(path) :: {:ok, map, warnings :: [String.t()]} | {:error, message :: String.t()}`. Error messages are `"path:line: reason"`. Duplicate keys: last wins + warning naming key and both lines.

- [ ] **Step 1: Write failing tests for the core grammar**

Create `test/ecs_task_def/env_file_test.exs`:

```elixir
defmodule EcsTaskDef.EnvFileTest do
  use ExUnit.Case, async: true

  alias EcsTaskDef.EnvFile

  @tmp System.tmp_dir!()

  defp write!(contents) do
    path = Path.join(@tmp, "envfile-test-#{System.unique_integer([:positive])}.env")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "basic KEY=VALUE pairs" do
    path = write!("FOO=bar\nBAZ=qux\n")
    assert {:ok, %{"FOO" => "bar", "BAZ" => "qux"}, []} = EnvFile.parse(path)
  end

  test "export prefix is accepted and ignored" do
    path = write!("export FOO=bar\n")
    assert {:ok, %{"FOO" => "bar"}, []} = EnvFile.parse(path)
  end

  test "full-line comments and blank lines are skipped" do
    path = write!("# a comment\n\n   \nFOO=bar\n  # indented comment\n")
    assert {:ok, %{"FOO" => "bar"}, []} = EnvFile.parse(path)
  end

  test "value is everything after the first =; may contain =" do
    path = write!("URL=https://x.example/a?b=c=d\n")
    assert {:ok, %{"URL" => "https://x.example/a?b=c=d"}, []} = EnvFile.parse(path)
  end

  test "empty value is legal" do
    path = write!("EMPTY=\n")
    assert {:ok, %{"EMPTY" => ""}, []} = EnvFile.parse(path)
  end

  test "one matching outer quote pair is stripped, no escape processing" do
    path = write!(~s(A="hello world"\nB='single'\nC="unbalanced\nD="keep \\n raw"\n))
    assert {:ok, map, []} = EnvFile.parse(path)
    assert map["A"] == "hello world"
    assert map["B"] == "single"
    assert map["C"] == ~s("unbalanced)
    assert map["D"] == ~s(keep \\n raw)
  end

  test "surrounding whitespace is trimmed from key and value" do
    path = write!("  FOO  =  bar  \n")
    assert {:ok, %{"FOO" => "bar"}, []} = EnvFile.parse(path)
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/ecs_task_def/env_file_test.exs`
Expected: FAIL — `EcsTaskDef.EnvFile` undefined.

- [ ] **Step 3: Implement the core parser**

Create `lib/ecs_task_def/env_file.ex`:

```elixir
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
        |> String.replace_prefix("\uFEFF", "")
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
                  ["#{path}: duplicate key #{key} on lines #{prev_no} and #{no}; using line #{no}"]

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
end
```

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/ecs_task_def/env_file_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 5: Write failing tests for errors, duplicates, CRLF/BOM**

Append to `test/ecs_task_def/env_file_test.exs`:

```elixir
  test "CRLF line endings and a UTF-8 BOM are tolerated" do
    path = write!("\uFEFF" <> "FOO=bar\r\nBAZ=qux\r\n")
    assert {:ok, %{"FOO" => "bar", "BAZ" => "qux"}, []} = EnvFile.parse(path)
  end

  test "duplicate keys: last wins, with a warning naming key and both lines" do
    path = write!("FOO=first\nBAR=x\nFOO=second\n")
    assert {:ok, %{"FOO" => "second", "BAR" => "x"}, [warning]} = EnvFile.parse(path)
    assert warning =~ "duplicate key FOO"
    assert warning =~ "lines 1 and 3"
  end

  test "line with no = is an error with file:line" do
    path = write!("FOO=ok\nnot a pair\n")
    assert {:error, message} = EnvFile.parse(path)
    assert message =~ "#{path}:2:"
    assert message =~ "no '='"
  end

  test "invalid key is an error with file:line" do
    path = write!("1BAD=value\n")
    assert {:error, message} = EnvFile.parse(path)
    assert message =~ "#{path}:1:"
    assert message =~ "invalid key"
  end

  test "missing file is an error" do
    assert {:error, message} = EnvFile.parse("/nonexistent/nope.env")
    assert message =~ "cannot read env file"
  end
```

- [ ] **Step 6: Run the full module's tests**

Run: `mix test test/ecs_task_def/env_file_test.exs`
Expected: PASS (12 tests) — the Step-3 implementation already covers these; if any fail, fix the implementation (not the tests) until green.

- [ ] **Step 7: Commit**

```bash
git add lib/ecs_task_def/env_file.ex test/ecs_task_def/env_file_test.exs
git commit -m "feat: EnvFile.parse implementing the spec's .env grammar with line-numbered errors"
```

---

### Task 4: EnvFile.merge — precedence + shadow warnings

**Files:**
- Modify: `lib/ecs_task_def/env_file.ex`
- Test: `test/ecs_task_def/env_file_test.exs`

API contract: `merge(file_map, sys_env_map) :: {extra :: [{String.t(), String.t()}], shadow_warnings :: [String.t()]}`. `extra` contains only file keys absent from the process env (they get appended to the spawned pkl process env; inherited env supplies the rest, so process-env-wins falls out naturally). Warnings fire only when both sides define a key with different values, and never contain the values.

- [ ] **Step 1: Write failing tests**

Append to `test/ecs_task_def/env_file_test.exs`:

```elixir
  describe "merge/3" do
    test "file keys absent from process env are extra; present keys are skipped" do
      {extra, warnings} =
        EnvFile.merge(%{"NEW" => "a", "SHADOWED" => "file"}, %{"SHADOWED" => "env"}, ".env")

      assert extra == [{"NEW", "a"}]
      assert [warning] = warnings
      assert warning =~ "SHADOWED is set in both the environment and .env"
      assert warning =~ "using the environment value"
      refute warning =~ "file"
      refute warning =~ "env\""
    end

    test "identical values produce no warning" do
      {extra, warnings} = EnvFile.merge(%{"SAME" => "x"}, %{"SAME" => "x"}, ".env")
      assert extra == []
      assert warnings == []
    end

    test "warnings never contain the differing values" do
      {_, [warning]} =
        EnvFile.merge(%{"SECRET" => "hunter2"}, %{"SECRET" => "hunter3"}, ".env.production")

      refute warning =~ "hunter2"
      refute warning =~ "hunter3"
      assert warning =~ ".env.production"
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/ecs_task_def/env_file_test.exs`
Expected: FAIL — `merge/3` undefined.

- [ ] **Step 3: Implement merge**

Append to `lib/ecs_task_def/env_file.ex` (inside the module):

```elixir
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
```

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/ecs_task_def/env_file_test.exs`
Expected: PASS (15 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/ecs_task_def/env_file.ex test/ecs_task_def/env_file_test.exs
git commit -m "feat: EnvFile.merge with process-env precedence and value-free shadow warnings"
```

---

### Task 5: Validator — embedded schema, Unicode pattern fix, friendly errors

**Files:**
- Create: `lib/ecs_task_def/validator.ex`
- Test: `test/ecs_task_def/validator_test.exs`

API contract: `validate(map) :: :ok | {:error, [String.t()]}` (already-formatted lines), `schema_version() :: String.t()` (e.g. `"v1.4.0"`), `preprocess_patterns/1` (public for unit tests). Formatted error lines look like `containerDefinitions[0].cpu: Type mismatch. Expected String but got Integer.`

- [ ] **Step 1: Write failing tests**

Create `test/ecs_task_def/validator_test.exs`:

```elixir
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
    assert length(lines) >= 3
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
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/ecs_task_def/validator_test.exs`
Expected: FAIL — `EcsTaskDef.Validator` undefined.

- [ ] **Step 3: Implement the Validator**

Create `lib/ecs_task_def/validator.ex`:

```elixir
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

  @doc "Validate a decoded task definition. :ok | {:error, [formatted_line]}"
  def validate(doc) when is_map(doc) do
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
```

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/ecs_task_def/validator_test.exs`
Expected: PASS (7 tests). If the "all violations" test fails on message wording, adjust the *assertions'* substrings to the library's actual messages — but only after reading them; the paths and the ≥3-error count must hold as written.

- [ ] **Step 5: Commit**

```bash
git add lib/ecs_task_def/validator.ex test/ecs_task_def/validator_test.exs
git commit -m "feat: Validator with embedded schema, (*UTF)(*UCP) pattern preprocessing, friendly error paths"
```

---

### Task 6: Output — atomic writes

**Files:**
- Create: `lib/ecs_task_def/output.ex`
- Test: `test/ecs_task_def/output_test.exs`

- [ ] **Step 1: Write failing tests**

Create `test/ecs_task_def/output_test.exs`:

```elixir
defmodule EcsTaskDef.OutputTest do
  use ExUnit.Case, async: true

  alias EcsTaskDef.Output

  setup do
    dir = Path.join(System.tmp_dir!(), "output-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "writes a new file", %{dir: dir} do
    path = Path.join(dir, "out.json")
    assert :ok = Output.write(path, ~s({"a":1}\n))
    assert File.read!(path) == ~s({"a":1}\n)
  end

  test "replaces an existing file atomically", %{dir: dir} do
    path = Path.join(dir, "out.json")
    File.write!(path, "old")
    assert :ok = Output.write(path, "new")
    assert File.read!(path) == "new"
  end

  test "on failure the existing destination is untouched and no temp remains", %{dir: dir} do
    missing_dir = Path.join(dir, "does-not-exist")
    path = Path.join(missing_dir, "out.json")
    assert {:error, message} = Output.write(path, "data")
    assert message =~ path
    refute File.exists?(missing_dir)
    assert File.ls!(dir) == []
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/ecs_task_def/output_test.exs`
Expected: FAIL — `EcsTaskDef.Output` undefined.

- [ ] **Step 3: Implement**

Create `lib/ecs_task_def/output.ex`:

```elixir
defmodule EcsTaskDef.Output do
  @moduledoc """
  Atomic output writes: temp file in the destination directory, then rename.
  An existing destination is only replaced by the final rename; on any failure
  the temp file is removed and the destination is left untouched.
  """

  def write(path, iodata) do
    dir = Path.dirname(path)

    tmp =
      Path.join(dir, ".#{Path.basename(path)}.tmp-#{System.unique_integer([:positive])}")

    with :ok <- File.write(tmp, iodata),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end
end
```

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/ecs_task_def/output_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/ecs_task_def/output.ex test/ecs_task_def/output_test.exs
git commit -m "feat: atomic Output.write (temp + rename, cleanup on failure)"
```

---

### Task 7: Preflight — locate pkl, enforce minimum version

**Files:**
- Create: `lib/ecs_task_def/preflight.ex`
- Create: `test/support/fake_pkl.sh`
- Test: `test/ecs_task_def/preflight_test.exs`
- Modify: `test/test_helper.exs`

API contract: `check(env \\ System.get_env()) :: {:ok, pkl_path, version_string} | {:error, message}`. PATH lookup honors the passed env's `"PATH"` so tests can inject fixture dirs. Minimum version `0.31.0` (module attribute).

- [ ] **Step 1: Create the fake pkl fixture script**

Create `test/support/fake_pkl.sh`:

```sh
#!/bin/sh
# Configurable stand-in for the pkl CLI, driven by environment variables:
#   FAKE_PKL_VERSION  version reported by --version   (default 0.31.1)
#   FAKE_PKL_STDOUT   stdout emitted by any other invocation
#   FAKE_PKL_STDERR   stderr emitted by any other invocation
#   FAKE_PKL_EXIT     exit code for any other invocation (default 0)
if [ "$1" = "--version" ]; then
  echo "Pkl ${FAKE_PKL_VERSION:-0.31.1} (fake, native)"
  exit 0
fi
[ -n "$FAKE_PKL_STDERR" ] && printf '%s\n' "$FAKE_PKL_STDERR" >&2
[ -n "$FAKE_PKL_STDOUT" ] && printf '%s\n' "$FAKE_PKL_STDOUT"
exit "${FAKE_PKL_EXIT:-0}"
```

Run: `chmod +x test/support/fake_pkl.sh && test/support/fake_pkl.sh --version`
Expected: `Pkl 0.31.1 (fake, native)`

- [ ] **Step 2: Add a test helper for building a PATH containing a `pkl` symlink to the fake**

Replace `test/test_helper.exs` with:

```elixir
defmodule EcsTaskDef.TestSupport do
  @doc """
  Creates a temp dir containing an executable named `pkl` that runs
  test/support/fake_pkl.sh, and returns that dir (for PATH injection).
  """
  def fake_pkl_dir do
    dir = Path.join(System.tmp_dir!(), "fake-pkl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    fake = Path.expand("test/support/fake_pkl.sh")
    File.ln_s!(fake, Path.join(dir, "pkl"))
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end

exclude = if System.find_executable("pkl"), do: [], else: [pkl: true]

if exclude != [] do
  IO.puts("NOTE: pkl not found on PATH — skipping :pkl integration tests")
end

ExUnit.start(exclude: exclude)
```

- [ ] **Step 3: Write failing tests**

Create `test/ecs_task_def/preflight_test.exs`:

```elixir
defmodule EcsTaskDef.PreflightTest do
  use ExUnit.Case, async: true

  alias EcsTaskDef.Preflight
  import EcsTaskDef.TestSupport

  test "finds pkl on PATH and returns its version" do
    dir = fake_pkl_dir()
    assert {:ok, path, "0.31.1"} = Preflight.check(%{"PATH" => dir})
    assert path == Path.join(dir, "pkl")
  end

  test "missing pkl yields an actionable error" do
    assert {:error, message} = Preflight.check(%{"PATH" => "/nonexistent-dir"})
    assert message =~ "pkl not found on PATH"
    assert message =~ "brew install pkl"
    assert message =~ "mise use pkl"
  end

  test "too-old pkl yields an error naming both versions" do
    dir = fake_pkl_dir()
    assert {:error, message} = Preflight.check(%{"PATH" => dir, "FAKE_PKL_VERSION" => "0.25.0"})
    assert message =~ "0.25.0"
    assert message =~ "0.31.0 or newer"
  end

  test "unparseable version output yields an error" do
    dir = fake_pkl_dir()
    assert {:error, message} = Preflight.check(%{"PATH" => dir, "FAKE_PKL_VERSION" => "banana"})
    assert message =~ "could not parse"
  end
end
```

- [ ] **Step 4: Run to verify failure**

Run: `mix test test/ecs_task_def/preflight_test.exs`
Expected: FAIL — `EcsTaskDef.Preflight` undefined.

- [ ] **Step 5: Implement**

Create `lib/ecs_task_def/preflight.ex`:

```elixir
defmodule EcsTaskDef.Preflight do
  @moduledoc """
  Finds the pkl CLI on PATH and enforces the minimum version the schema and
  codegen are tested against. Runs before anything else so failures are early
  and actionable.
  """

  @minimum "0.31.0"

  def minimum_version, do: @minimum

  @doc "check(env) :: {:ok, pkl_path, version} | {:error, message}"
  def check(env \\ System.get_env()) do
    path_var = Map.get(env, "PATH", "")

    case find_executable("pkl", path_var) do
      nil ->
        {:error,
         "pkl not found on PATH. Install it with `brew install pkl` or " <>
           "`mise use pkl@latest` (version #{@minimum} or newer required), then re-run."}

      pkl_path ->
        check_version(pkl_path, env)
    end
  end

  defp check_version(pkl_path, env) do
    {output, 0} = System.cmd(pkl_path, ["--version"], env: extra_env(env), stderr_to_stdout: true)

    case Regex.run(~r/Pkl (\d+\.\d+\.\d+)/, output) do
      [_, version] ->
        if Version.compare(version, @minimum) == :lt do
          {:error,
           "pkl #{version} is too old; ecs-task-def needs #{@minimum} or newer. " <>
             "Upgrade with `brew upgrade pkl` or `mise use pkl@latest`."}
        else
          {:ok, pkl_path, version}
        end

      nil ->
        {:error, "could not parse `pkl --version` output: #{inspect(String.trim(output))}"}
    end
  rescue
    e in [ErlangError, MatchError] ->
      {:error, "failed to run `#{pkl_path} --version`: #{Exception.message(e)}"}
  end

  # System.find_executable/1 only consults the real process PATH; this variant
  # honors an injected env for testability.
  defp find_executable(name, path_var) do
    path_var
    |> String.split(":", trim: true)
    |> Enum.map(&Path.join(&1, name))
    |> Enum.find(fn candidate ->
      case File.stat(candidate) do
        {:ok, %File.Stat{type: type, mode: mode}} when type in [:regular, :symlink] ->
          Bitwise.band(mode, 0o111) != 0

        _ ->
          File.exists?(candidate)
      end
    end)
  end

  # Pass FAKE_PKL_* through for the test fixture; harmless in production.
  defp extra_env(env) do
    for {k, v} <- env, String.starts_with?(k, "FAKE_PKL_"), do: {k, v}
  end
end
```

- [ ] **Step 6: Run to verify pass**

Run: `mix test test/ecs_task_def/preflight_test.exs`
Expected: PASS (4 tests). Note: symlink stat — `File.stat` follows symlinks, so `type` will be `:regular`; if the executable-bit check misbehaves on the symlink, switch the `Enum.find` predicate to `File.exists?(candidate)` only (the fake and real pkl are both executable; PATH lookup precision is not worth more code).

- [ ] **Step 7: Commit**

```bash
git add lib/ecs_task_def/preflight.ex test/ecs_task_def/preflight_test.exs test/support/fake_pkl.sh test/test_helper.exs
git commit -m "feat: Preflight pkl discovery + minimum-version enforcement, fake-pkl test fixture"
```

---

### Task 8: Pkl — spawn eval with merged env, separate stdout/stderr

**Files:**
- Create: `lib/ecs_task_def/pkl.ex`
- Test: `test/ecs_task_def/pkl_test.exs`

API contract: `eval(pkl_path, input_path, extra_env :: [{k, v}]) :: {:ok, json_string, stderr :: String.t()} | {:error, {exit_code, stderr :: String.t()}}`. Stderr is captured separately via `/bin/sh` redirection to a temp file (deterministic header-then-stderr ordering at the CLI layer; POSIX-only is fine — supported platforms are macOS/Linux).

- [ ] **Step 1: Write failing tests (fake pkl for failure modes, real pkl for the happy path)**

Create `test/ecs_task_def/pkl_test.exs`:

```elixir
defmodule EcsTaskDef.PklTest do
  use ExUnit.Case, async: true

  alias EcsTaskDef.Pkl
  import EcsTaskDef.TestSupport

  defp fake_pkl do
    Path.join(fake_pkl_dir(), "pkl")
  end

  test "success returns stdout and separately captured stderr" do
    System.put_env("FAKE_PKL_STDOUT", ~s({"family":"x"}))
    System.put_env("FAKE_PKL_STDERR", "some warning")
    on_exit(fn -> System.delete_env("FAKE_PKL_STDOUT"); System.delete_env("FAKE_PKL_STDERR") end)

    assert {:ok, out, stderr} = Pkl.eval(fake_pkl(), "ignored.pkl", [])
    assert out == ~s({"family":"x"}\n)
    assert stderr == "some warning\n"
  end

  test "failure returns exit code and captured stderr" do
    System.put_env("FAKE_PKL_EXIT", "42")
    System.put_env("FAKE_PKL_STDERR", "-- Pkl Error --\nboom")
    on_exit(fn -> System.delete_env("FAKE_PKL_EXIT"); System.delete_env("FAKE_PKL_STDERR") end)

    assert {:error, {42, stderr}} = Pkl.eval(fake_pkl(), "ignored.pkl", [])
    assert stderr =~ "Pkl Error"
    assert stderr =~ "boom"
  end

  test "extra_env reaches the child process" do
    # fake_pkl echoes FAKE_PKL_STDOUT; set it ONLY via extra_env
    assert {:ok, out, _} = Pkl.eval(fake_pkl(), "ignored.pkl", [{"FAKE_PKL_STDOUT", "from-extra"}])
    assert out == "from-extra\n"
  end

  @tag :pkl
  test "real pkl evaluates a trivial module to JSON" do
    dir = Path.join(System.tmp_dir!(), "pkl-eval-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    input = Path.join(dir, "t.pkl")
    File.write!(input, ~s(name = "hello \\(read("env:WHO"))"\n))

    pkl = System.find_executable("pkl")
    assert {:ok, out, _stderr} = Pkl.eval(pkl, input, [{"WHO", "world"}])
    assert JSON.decode!(out) == %{"name" => "hello world"}
  end

  @tag :pkl
  test "real pkl missing env var fails with file:line in stderr" do
    dir = Path.join(System.tmp_dir!(), "pkl-eval-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    input = Path.join(dir, "t.pkl")
    File.write!(input, ~s(name = read("env:DOES_NOT_EXIST_XYZ")\n))

    pkl = System.find_executable("pkl")
    assert {:error, {code, stderr}} = Pkl.eval(pkl, input, [])
    assert code != 0
    assert stderr =~ "Cannot find resource `env:DOES_NOT_EXIST_XYZ`"
    assert stderr =~ "t.pkl"
  end
end
```

Note: the first three tests set `FAKE_PKL_*` via the process env (inherited by the child), so this file must NOT be `async: true` with other files mutating the same vars — it is the only file doing so; keep `async: true` but never add `FAKE_PKL_*` System.put_env calls elsewhere.

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/ecs_task_def/pkl_test.exs`
Expected: FAIL — `EcsTaskDef.Pkl` undefined.

- [ ] **Step 3: Implement**

Create `lib/ecs_task_def/pkl.ex`:

```elixir
defmodule EcsTaskDef.Pkl do
  @moduledoc """
  Spawns `pkl eval -f json INPUT` with the merged environment and captures
  stdout (the JSON) and stderr (diagnostics) separately.

  Erlang ports cannot capture a child's stderr separately, so the child runs
  under `/bin/sh -c 'exec "$0" "$@" 2>"$FILE"'` with stderr redirected to a
  temp file (macOS/Linux only, which matches the supported platforms).
  """

  def eval(pkl_path, input_path, extra_env) do
    stderr_file =
      Path.join(
        System.tmp_dir!(),
        "ecs-task-def-stderr-#{System.unique_integer([:positive])}"
      )

    try do
      {stdout, exit_code} =
        System.cmd(
          "/bin/sh",
          ["-c", ~S(exec "$0" "$@" 2>"$ECS_TASK_DEF_STDERR_FILE"), pkl_path, "eval", "-f", "json", input_path],
          env: [{"ECS_TASK_DEF_STDERR_FILE", stderr_file} | extra_env]
        )

      stderr =
        case File.read(stderr_file) do
          {:ok, contents} -> contents
          {:error, _} -> ""
        end

      if exit_code == 0 do
        {:ok, stdout, stderr}
      else
        {:error, {exit_code, stderr}}
      end
    after
      File.rm(stderr_file)
    end
  end
end
```

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/ecs_task_def/pkl_test.exs`
Expected: PASS — 5 tests (or 3 if pkl absent, with the skip notice).

- [ ] **Step 5: Commit**

```bash
git add lib/ecs_task_def/pkl.ex test/ecs_task_def/pkl_test.exs
git commit -m "feat: Pkl runner with merged env and separately captured stderr"
```

---

### Task 9: mix ecs.regen_schema — generate committed artifacts

**Files:**
- Create: `lib/mix/tasks/ecs.regen_schema.ex`
- Create (generated): `pkl/EcsSchema.pkl`, `priv/EcsSchema.pkl` (and re-download `priv/schema.json`)

This task needs network + real pkl (dev/CI-time only, never at user runtime).

- [ ] **Step 1: Implement the mix task**

Create `lib/mix/tasks/ecs.regen_schema.ex`:

```elixir
defmodule Mix.Tasks.Ecs.RegenSchema do
  @shortdoc "Regenerate priv/schema.json and pkl/EcsSchema.pkl from the pinned awslabs schema"

  @moduledoc """
  Downloads the awslabs amazon-ecs-intellisense-schema at the commit pinned in
  EcsTaskDef.SchemaPin, regenerates the typed Pkl module with the official
  pkl-pantry codegen, and refreshes all three committed artifacts together:

    * priv/schema.json    (pristine copy, embedded for the validator)
    * pkl/EcsSchema.pkl   (source of truth, published as a Pkl package)
    * priv/EcsSchema.pkl  (embedded copy for `init --vendor`)

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
      schema_file = Path.join(tmp, "ecs-schema.json")
      download!(EcsTaskDef.SchemaPin.raw_url(), schema_file)

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

      targets = %{
        "priv/schema.json" => File.read!(schema_file),
        "pkl/EcsSchema.pkl" => File.read!(generated),
        "priv/EcsSchema.pkl" => File.read!(generated)
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
end
```

- [ ] **Step 2: Run it and inspect the artifacts**

Run: `mix ecs.regen_schema && wc -l pkl/EcsSchema.pkl && head -7 pkl/EcsSchema.pkl && diff priv/EcsSchema.pkl pkl/EcsSchema.pkl && echo IDENTICAL`
Expected: three `wrote …` lines; ≈1,415 lines; header `module EcsSchema` with the AWS doc comment; `IDENTICAL`.

- [ ] **Step 3: Verify --check passes when clean and fails when dirty**

Run: `mix ecs.regen_schema --check`
Expected: `regen check: all artifacts up to date`

Run: `echo "// dirty" >> pkl/EcsSchema.pkl && mix ecs.regen_schema --check; git checkout pkl/EcsSchema.pkl`
Expected: `regen check FAILED — stale artifacts: pkl/EcsSchema.pkl…` (nonzero exit), then restored.

- [ ] **Step 4: Amend-eval smoke test (real pkl)**

Run:

```bash
cat > /tmp/regen-smoke.pkl <<'EOF'
amends "pkl/EcsSchema.pkl"
family = "smoke"
containerDefinitions { new { name = "c"; image = "img" } }
EOF
pkl eval -f json /tmp/regen-smoke.pkl
```

Expected: JSON with `"family": "smoke"` and one container. (Run from the repo root; the amends path is relative to the pkl file — if pkl resolves it relative to the module, use the absolute path `amends "/full/path/to/repo/pkl/EcsSchema.pkl"` in the smoke file.)

- [ ] **Step 5: Commit**

```bash
git add lib/mix/tasks/ecs.regen_schema.ex pkl/EcsSchema.pkl priv/EcsSchema.pkl priv/schema.json
git commit -m "feat: mix ecs.regen_schema (pinned download + pantry codegen + --check) and generated artifacts"
```

---

### Task 10: Scaffold — init templates, never-overwrite

**Files:**
- Create: `lib/ecs_task_def/scaffold.ex`
- Test: `test/ecs_task_def/scaffold_test.exs`

API contract: `init(dir, vendor?) :: {:ok, [written_path]} | {:error, {:exists, [path]}}`. Default template amends the package URL pinned to the app's own version; `--vendor` writes `EcsSchema.pkl` beside it and amends `"EcsSchema.pkl"`.

- [ ] **Step 1: Write failing tests**

Create `test/ecs_task_def/scaffold_test.exs`:

```elixir
defmodule EcsTaskDef.ScaffoldTest do
  use ExUnit.Case, async: true

  alias EcsTaskDef.Scaffold

  setup do
    dir = Path.join(System.tmp_dir!(), "scaffold-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "default init writes mytask.pkl amending the versioned package URL", %{dir: dir} do
    assert {:ok, [task_path]} = Scaffold.init(dir, false)
    assert task_path == Path.join(dir, "mytask.pkl")
    contents = File.read!(task_path)
    version = Application.spec(:ecs_task_def, :vsn) |> to_string()

    assert contents =~
             ~s[amends "package://pkg.pkl-lang.org/github.com/djgoku/aws-ecs-task-definition-generator/ecs-task-def@#{version}#/EcsSchema.pkl"]

    assert contents =~ ~s[read("env:]
  end

  test "vendor init writes both files and amends the local module", %{dir: dir} do
    assert {:ok, paths} = Scaffold.init(dir, true)
    assert Path.join(dir, "mytask.pkl") in paths
    assert Path.join(dir, "EcsSchema.pkl") in paths
    assert File.read!(Path.join(dir, "mytask.pkl")) =~ ~s[amends "EcsSchema.pkl"]
    assert File.read!(Path.join(dir, "EcsSchema.pkl")) =~ "module EcsSchema"
  end

  test "refuses to overwrite and writes nothing", %{dir: dir} do
    File.write!(Path.join(dir, "EcsSchema.pkl"), "existing")
    assert {:error, {:exists, [conflict]}} = Scaffold.init(dir, true)
    assert conflict == Path.join(dir, "EcsSchema.pkl")
    refute File.exists?(Path.join(dir, "mytask.pkl"))
    assert File.read!(Path.join(dir, "EcsSchema.pkl")) == "existing"
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/ecs_task_def/scaffold_test.exs`
Expected: FAIL — `EcsTaskDef.Scaffold` undefined.

- [ ] **Step 3: Implement**

Create `lib/ecs_task_def/scaffold.ex`:

```elixir
defmodule EcsTaskDef.Scaffold do
  @moduledoc """
  `init` scaffolding. Writes a starter mytask.pkl (and, with vendor: true, the
  embedded EcsSchema.pkl). Never overwrites: any pre-existing target aborts the
  whole scaffold before anything is written.
  """

  @package_base "package://pkg.pkl-lang.org/github.com/djgoku/aws-ecs-task-definition-generator/ecs-task-def"

  def init(dir, vendor?) do
    files = files(dir, vendor?)
    existing = for {path, _} <- files, File.exists?(path), do: path

    if existing == [] do
      for {path, contents} <- files, do: File.write!(path, contents)
      {:ok, Enum.map(files, &elem(&1, 0))}
    else
      {:error, {:exists, existing}}
    end
  end

  defp files(dir, false) do
    [{Path.join(dir, "mytask.pkl"), starter_template(package_amends())}]
  end

  defp files(dir, true) do
    [
      {Path.join(dir, "mytask.pkl"), starter_template(~s(amends "EcsSchema.pkl"))},
      {Path.join(dir, "EcsSchema.pkl"), File.read!(embedded_schema_pkl())}
    ]
  end

  defp package_amends do
    version = Application.spec(:ecs_task_def, :vsn) |> to_string()
    ~s(amends "#{@package_base}@#{version}#/EcsSchema.pkl")
  end

  defp embedded_schema_pkl, do: Path.join(:code.priv_dir(:ecs_task_def), "EcsSchema.pkl")

  defp starter_template(amends_line) do
    """
    #{amends_line}

    family = "my-app"
    networkMode = "awsvpc"
    requiresCompatibilities { "FARGATE" }
    cpu = "256"
    memory = "512"

    containerDefinitions {
      new {
        name = "web"
        image = "\\(read("env:ECR_REPO")):\\(read("env:IMAGE_TAG"))"
        essential = true
        portMappings {
          new {
            containerPort = 8080
            protocol = "tcp"
          }
        }
      }
    }
    """
  end
end
```

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/ecs_task_def/scaffold_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/ecs_task_def/scaffold.ex test/ecs_task_def/scaffold_test.exs
git commit -m "feat: Scaffold init (package-URL default, --vendor local copy, never overwrites)"
```

---

### Task 11: CLI — parsing, dispatch, pipeline, exit codes

**Files:**
- Modify: `lib/ecs_task_def/cli.ex` (replace the Task-1 placeholder entirely)
- Test: `test/ecs_task_def/cli_test.exs`

Contract recap: `run(argv) :: exit_code`. Progress/warnings → stderr; JSON → stdout (or `-o` file). Exit codes 0–6 per the spec table. NimbleOptions validates parsed options; unknown flags get a jaro-distance "did you mean" suggestion.

- [ ] **Step 1: Write failing tests (unit level, fake pkl)**

Create `test/ecs_task_def/cli_test.exs`:

```elixir
defmodule EcsTaskDef.CLITest do
  use ExUnit.Case
  # NOT async: this file swaps PATH via the env argument only — but capture_io
  # of grouped stderr is simpler serialized.

  import ExUnit.CaptureIO
  import EcsTaskDef.TestSupport

  alias EcsTaskDef.CLI

  setup do
    dir = Path.join(System.tmp_dir!(), "cli-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp run_with_env(argv, env) do
    # CLI.run/2 takes the environment map for testability; run/1 delegates
    # with System.get_env().
    stderr = capture_io(:stderr, fn -> send(self(), {:code, CLI.run(argv, env)}) end)
    assert_received {:code, code}
    {code, stderr}
  end

  test "no args prints usage and exits 1" do
    {code, err} = run_with_env([], %{"PATH" => "/nonexistent"})
    assert code == 1
    assert err =~ "Usage:"
    assert err =~ "generate"
    assert err =~ "init"
  end

  test "unknown flag suggests the nearest real one" do
    {code, err} = run_with_env(["generate", "in.pkl", "--ouput", "x"], %{"PATH" => "/nonexistent"})
    assert code == 1
    assert err =~ "unknown option --ouput"
    assert err =~ "did you mean --output?"
  end

  test "missing pkl exits 2 with install hint" do
    {code, err} = run_with_env(["generate", "in.pkl"], %{"PATH" => "/nonexistent"})
    assert code == 2
    assert err =~ "pkl not found on PATH"
  end

  test "missing env file exits 3", %{dir: dir} do
    fake = fake_pkl_dir()
    input = Path.join(dir, "t.pkl")
    File.write!(input, "family = \"x\"\n")

    {code, err} =
      run_with_env(
        ["generate", input, "--env-file", Path.join(dir, "missing.env")],
        %{"PATH" => fake}
      )

    assert code == 3
    assert err =~ "cannot read env file"
  end

  test "pkl eval failure exits 4, header then pkl stderr", %{dir: dir} do
    fake = fake_pkl_dir()
    input = Path.join(dir, "t.pkl")
    File.write!(input, "irrelevant")
    System.put_env("FAKE_PKL_EXIT", "1")
    System.put_env("FAKE_PKL_STDERR", "-- Pkl Error --\nboom at line 3")
    on_exit(fn -> System.delete_env("FAKE_PKL_EXIT"); System.delete_env("FAKE_PKL_STDERR") end)

    {code, err} = run_with_env(["generate", input], %{"PATH" => fake})
    assert code == 4
    assert err =~ "pkl eval failed"
    assert err =~ "boom at line 3"
    # header comes before pkl's stderr
    assert :binary.match(err, "pkl eval failed") < :binary.match(err, "boom at line 3")
  end

  test "schema-invalid output exits 5 listing violations", %{dir: dir} do
    fake = fake_pkl_dir()
    input = Path.join(dir, "t.pkl")
    File.write!(input, "irrelevant")
    System.put_env("FAKE_PKL_STDOUT", ~s({"cpu": 256}))
    on_exit(fn -> System.delete_env("FAKE_PKL_STDOUT") end)

    {code, err} = run_with_env(["generate", input], %{"PATH" => fake})
    assert code == 5
    assert err =~ "schema validation failed"
    assert err =~ "cpu: Type mismatch"
    assert err =~ "family"
  end

  test "success writes JSON to stdout, progress to stderr", %{dir: dir} do
    fake = fake_pkl_dir()
    input = Path.join(dir, "t.pkl")
    File.write!(input, "irrelevant")

    System.put_env(
      "FAKE_PKL_STDOUT",
      ~s({"family":"x","containerDefinitions":[{"name":"c","image":"i"}]})
    )

    on_exit(fn -> System.delete_env("FAKE_PKL_STDOUT") end)

    stdout =
      capture_io(fn ->
        stderr = capture_io(:stderr, fn -> send(self(), {:code, CLI.run(["generate", input], %{"PATH" => fake})}) end)
        send(self(), {:stderr, stderr})
      end)

    assert_received {:code, 0}
    assert_received {:stderr, stderr}
    assert JSON.decode!(stdout)["family"] == "x"
    assert stderr =~ "✓ pkl 0.31.1 found"
    assert stderr =~ "✓ validated against ECS schema"
    assert stderr =~ "awslabs@#{EcsTaskDef.SchemaPin.short_sha()}"
  end

  test "-o writes the file and unwritable output dir exits 6", %{dir: dir} do
    fake = fake_pkl_dir()
    input = Path.join(dir, "t.pkl")
    File.write!(input, "irrelevant")

    System.put_env(
      "FAKE_PKL_STDOUT",
      ~s({"family":"x","containerDefinitions":[{"name":"c","image":"i"}]})
    )

    on_exit(fn -> System.delete_env("FAKE_PKL_STDOUT") end)

    out = Path.join(dir, "out.json")
    {code, err} = run_with_env(["generate", input, "-o", out], %{"PATH" => fake})
    assert code == 0
    assert err =~ "wrote #{out}"
    assert JSON.decode!(File.read!(out))["family"] == "x"

    bad_out = Path.join([dir, "no-such-dir", "out.json"])
    {code2, err2} = run_with_env(["generate", input, "--output", bad_out], %{"PATH" => fake})
    assert code2 == 6
    assert err2 =~ "cannot write"
  end

  test "init scaffolds and refuses to overwrite with exit 6", %{dir: dir} do
    {code, err} = run_with_env(["init", dir], %{"PATH" => "/nonexistent"})
    assert code == 0
    assert err =~ "created #{Path.join(dir, "mytask.pkl")}"

    {code2, err2} = run_with_env(["init", dir], %{"PATH" => "/nonexistent"})
    assert code2 == 6
    assert err2 =~ "already exist"
    assert err2 =~ "mytask.pkl"
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/ecs_task_def/cli_test.exs`
Expected: FAIL — `CLI.run/2` undefined (placeholder only has `run/1`).

- [ ] **Step 3: Implement the CLI**

Replace `lib/ecs_task_def/cli.ex` entirely with:

```elixir
defmodule EcsTaskDef.CLI do
  @moduledoc """
  argv → exit code. All human output goes to stderr; the generated JSON is the
  only thing written to stdout (when --output is not given).
  """

  alias EcsTaskDef.{EnvFile, Output, Pkl, Preflight, Scaffold, SchemaPin, Validator}

  @generate_opts NimbleOptions.new!(
                   output: [type: :string, doc: "Write the JSON here instead of stdout."],
                   env_file: [type: :string, doc: "KEY=VALUE defaults merged under the process environment."]
                 )

  @init_opts NimbleOptions.new!(
               vendor: [
                 type: :boolean,
                 default: false,
                 doc: "Vendor EcsSchema.pkl into the target directory; amends points at the local file."
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
    with {:ok, input, opts} <- parse(args, @generate_opts, [output: :string, env_file: :string], [o: :output], 1),
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
        info("✓ validated against ECS schema #{Validator.schema_version()} (awslabs@#{SchemaPin.short_sha()})")
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
          info("next: set your env vars and run `ecs-task-def generate #{Path.join(dir, "mytask.pkl")}`")
          0

        {:error, {:exists, paths}} ->
          error("refusing to overwrite; these files already exist:")
          Enum.each(paths, fn p -> IO.puts(:stderr, "  " <> p) end)
          error("move them aside or run init in an empty directory")
          6
      end
    else
      {:exit, code} -> code
    end
  end

  # -- parsing ----------------------------------------------------------------

  # arity: 1 = exactly one positional; {0, 1} = zero or one positional
  defp parse(args, nimble_schema, strict, aliases, arity) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: strict, aliases: aliases)

    cond do
      invalid != [] ->
        {flag, _} = hd(invalid)
        usage_error_exit("unknown option #{flag}#{suggestion(flag)}")

      arity == 1 and length(positional) != 1 ->
        usage_error_exit("expected exactly one INPUT.pkl argument, got #{length(positional)}")

      arity == {0, 1} and length(positional) > 1 ->
        usage_error_exit("expected at most one DIR argument, got #{length(positional)}")

      true ->
        case NimbleOptions.validate(opts, nimble_schema) do
          {:ok, validated} ->
            {:ok, List.first(positional), validated}

          {:error, %NimbleOptions.ValidationError{} = e} ->
            usage_error_exit(Exception.message(e))
        end
    end
  end

  defp suggestion(flag) do
    {best, distance} =
      @known_flags
      |> Enum.map(fn known -> {known, String.jaro_distance(flag, known)} end)
      |> Enum.max_by(fn {_, d} -> d end)

    if distance > 0.7, do: ", did you mean #{best}?", else: ""
  end

  defp usage_error_exit(message) do
    error(message)
    {:exit, 1}
  end

  defp usage_error(message) do
    error(message)
    usage(:stderr)
    1
  end

  defp usage(device) do
    IO.puts(device, """
    Usage:
      ecs-task-def generate INPUT.pkl [--output|-o PATH] [--env-file PATH]
      ecs-task-def init [DIR] [--vendor]

    generate options:
    #{NimbleOptions.docs(@generate_opts)}
    init options:
    #{NimbleOptions.docs(@init_opts)}
    """)

    if device == :stdio, do: 0, else: 1
  end

  defp info(line), do: IO.puts(:stderr, line)
  defp error(line), do: IO.puts(:stderr, "error: " <> line)
end
```

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/ecs_task_def/cli_test.exs`
Expected: PASS (10 tests). Two likely adjustment points, fix implementation not tests: (a) `usage_error/1` for bare `run([])` must both print usage and return 1; (b) `:binary.match/2` returns `{pos, len}` tuples — tuple comparison gives header-before-stderr ordering correctly.

- [ ] **Step 5: Run the whole suite**

Run: `mix test`
Expected: all tests pass, no warnings.

- [ ] **Step 6: Commit**

```bash
git add lib/ecs_task_def/cli.ex test/ecs_task_def/cli_test.exs
git commit -m "feat: CLI with NimbleOptions-validated commands, staged pipeline, spec exit codes"
```

---

### Task 12: End-to-end integration tests (real pkl)

**Files:**
- Create: `test/integration/generate_test.exs`
- Create: `test/fixtures/starter_golden.json`

- [ ] **Step 1: Write the integration tests**

Create `test/integration/generate_test.exs`:

```elixir
defmodule EcsTaskDef.Integration.GenerateTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  alias EcsTaskDef.CLI

  @moduletag :pkl

  setup do
    dir = Path.join(System.tmp_dir!(), "e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp real_env(extra \\ %{}) do
    Map.merge(System.get_env(), extra)
  end

  test "init --vendor then generate produces valid JSON end to end", %{dir: dir} do
    capture_io(:stderr, fn ->
      assert CLI.run(["init", dir, "--vendor"], real_env()) == 0
    end)

    out = Path.join(dir, "task.json")

    stderr =
      capture_io(:stderr, fn ->
        code =
          CLI.run(
            ["generate", Path.join(dir, "mytask.pkl"), "-o", out],
            real_env(%{"ECR_REPO" => "123.dkr.ecr.us-east-1.amazonaws.com/web", "IMAGE_TAG" => "v1"})
          )

        send(self(), {:code, code})
      end)

    assert_received {:code, 0}
    assert stderr =~ "✓ evaluated"
    doc = out |> File.read!() |> JSON.decode!()
    assert doc["family"] == "my-app"
    assert hd(doc["containerDefinitions"])["image"] == "123.dkr.ecr.us-east-1.amazonaws.com/web:v1"
    assert :ok = EcsTaskDef.Validator.validate(doc)
  end

  test "missing env var: exit 4 and pkl's file:line error surfaces", %{dir: dir} do
    capture_io(:stderr, fn ->
      assert CLI.run(["init", dir, "--vendor"], real_env()) == 0
    end)

    stderr =
      capture_io(:stderr, fn ->
        code =
          CLI.run(
            ["generate", Path.join(dir, "mytask.pkl")],
            real_env(%{"ECR_REPO" => "repo"}) |> Map.delete("IMAGE_TAG")
          )

        send(self(), {:code, code})
      end)

    assert_received {:code, 4}
    assert stderr =~ "Cannot find resource `env:IMAGE_TAG`"
    assert stderr =~ "mytask.pkl"
  end

  test "env file supplies defaults; real env wins with shadow warning", %{dir: dir} do
    capture_io(:stderr, fn ->
      assert CLI.run(["init", dir, "--vendor"], real_env()) == 0
    end)

    env_file = Path.join(dir, ".env")
    File.write!(env_file, "ECR_REPO=from-file\nIMAGE_TAG=file-tag\n")

    out = Path.join(dir, "task.json")

    stderr =
      capture_io(:stderr, fn ->
        code =
          CLI.run(
            ["generate", Path.join(dir, "mytask.pkl"), "-o", out, "--env-file", env_file],
            real_env(%{"ECR_REPO" => "from-env"}) |> Map.delete("IMAGE_TAG")
          )

        send(self(), {:code, code})
      end)

    assert_received {:code, 0}
    assert stderr =~ "warning: ECR_REPO is set in both the environment and #{env_file}"
    doc = out |> File.read!() |> JSON.decode!()
    assert hd(doc["containerDefinitions"])["image"] == "from-env:file-tag"
  end

  test "typo'd field in the template fails eval with the field name", %{dir: dir} do
    capture_io(:stderr, fn ->
      assert CLI.run(["init", dir, "--vendor"], real_env()) == 0
    end)

    task = Path.join(dir, "mytask.pkl")
    File.write!(task, String.replace(File.read!(task), "networkMode", "networkMoode"))

    stderr =
      capture_io(:stderr, fn ->
        code =
          CLI.run(
            ["generate", task],
            real_env(%{"ECR_REPO" => "r", "IMAGE_TAG" => "t"})
          )

        send(self(), {:code, code})
      end)

    assert_received {:code, 4}
    assert stderr =~ "networkMoode"
  end
end
```

- [ ] **Step 2: Run with real pkl**

Run: `mix test test/integration/generate_test.exs`
Expected: PASS (4 tests). Watch for: the vendored `amends "EcsSchema.pkl"` resolves relative to `mytask.pkl`'s directory — pkl resolves relative module URIs against the importing module's location, which is why `init` writes them side by side.

- [ ] **Step 3: Commit**

```bash
git add test/integration/generate_test.exs
git commit -m "test: end-to-end integration coverage (happy path, env precedence, eval failures)"
```

---

### Task 13: Real-world fixture corpus + golden tests

**Files:**
- Create: `test/fixtures/corpus/nginx_fargate.pkl`
- Create: `test/fixtures/corpus/nginx_fargate.golden.json`
- Create: `test/integration/corpus_test.exs`

- [ ] **Step 1: Add the AWS-authored golden JSON (verbatim from aws-samples)**

Create `test/fixtures/corpus/nginx_fargate.golden.json` — content fetched 2026-07-17 from
`https://raw.githubusercontent.com/aws-samples/aws-containers-task-definitions/master/nginx/nginx_fargate.json`:

```json
{
  "requiresCompatibilities": [
    "FARGATE"
  ],
  "containerDefinitions": [
    {
      "name": "nginx",
      "image": "nginx:latest",
      "memory": 256,
      "cpu": 256,
      "essential": true,
      "portMappings": [
        {
          "containerPort": 80,
          "protocol": "tcp"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "awslogs-nginx-ecs",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ],
  "volumes": [],
  "networkMode": "awsvpc",
  "placementConstraints": [],
  "family": "nginx",
  "memory": "512",
  "cpu": "256"
}
```

- [ ] **Step 2: Port it to Pkl**

Create `test/fixtures/corpus/nginx_fargate.pkl`:

```pkl
// Ported from aws-samples/aws-containers-task-definitions nginx/nginx_fargate.json
amends "../../../pkl/EcsSchema.pkl"

family = "nginx"
networkMode = "awsvpc"
requiresCompatibilities { "FARGATE" }
cpu = "256"
memory = "512"
volumes {}
placementConstraints {}

containerDefinitions {
  new {
    name = "nginx"
    image = "nginx:latest"
    memory = 256
    cpu = 256
    essential = true
    portMappings {
      new {
        containerPort = 80
        protocol = "tcp"
      }
    }
    logConfiguration {
      logDriver = "awslogs"
      options {
        ["awslogs-group"] = "awslogs-nginx-ecs"
        ["awslogs-region"] = "us-east-1"
        ["awslogs-stream-prefix"] = "ecs"
      }
    }
  }
}
```

- [ ] **Step 3: Write the corpus test (data-driven — one test per .pkl in the corpus dir)**

Create `test/integration/corpus_test.exs`:

```elixir
defmodule EcsTaskDef.Integration.CorpusTest do
  use ExUnit.Case

  @moduletag :pkl

  @corpus_dir Path.expand("../fixtures/corpus", __DIR__)

  for pkl_file <- Path.wildcard(Path.join(Path.expand("../fixtures/corpus", __DIR__), "*.pkl")) do
    name = Path.basename(pkl_file, ".pkl")

    test "corpus fixture #{name} matches its AWS-authored golden JSON and validates" do
      pkl_file = Path.join(@corpus_dir, "#{unquote(name)}.pkl")
      golden_file = Path.join(@corpus_dir, "#{unquote(name)}.golden.json")

      pkl = System.find_executable("pkl")
      assert {:ok, out, _stderr} = EcsTaskDef.Pkl.eval(pkl, pkl_file, [])

      generated = JSON.decode!(out)
      golden = golden_file |> File.read!() |> JSON.decode!()

      assert generated == golden
      assert :ok = EcsTaskDef.Validator.validate(generated)
      assert :ok = EcsTaskDef.Validator.validate(golden)
    end
  end
end
```

- [ ] **Step 4: Run and reconcile**

Run: `mix test test/integration/corpus_test.exs`
Expected: PASS. If the map comparison fails, diff the two decoded maps — likely causes and their fixes: an omitted-vs-empty field (add the empty listing to the .pkl, as done for `volumes {}`), or a container-level int rendered as string (use the unquoted int in the .pkl). Fix the .pkl port, never the golden file.

- [ ] **Step 5: Port the rest of the corpus (repeatable recipe)**

For each remaining source file, apply exactly the Step-1→Step-4 procedure (fetch → save as `test/fixtures/corpus/<name>.golden.json` verbatim → hand-port to `<name>.pkl` amending `../../../pkl/EcsSchema.pkl` with the same field-by-field translation rules: top-level `cpu`/`memory` are strings, container-level are ints, string-keyed maps use `["key"] = value` Mapping syntax, arrays use `Listing { new { … } }`, empty arrays present in the source become explicit empty listings). The data-driven corpus test picks each pair up automatically — no test-code changes.

Sources to port (all from `aws-samples/aws-containers-task-definitions`, raw URLs follow the nginx pattern):

- `nginx/nginx_ec2.json`
- `tomcat/tomcat_ec2.json`
- `gunicorn/gunicorn_fargate.json`
- one EFS-volume example from the AWS developer-guide page
  `https://docs.aws.amazon.com/AmazonECS/latest/developerguide/example_task_definitions.html`
  (copy the JSON into the golden file verbatim; name the pair `docs_efs`)

Run after each port: `mix test test/integration/corpus_test.exs`
Expected: one more passing test per pair.

- [ ] **Step 6: Commit**

```bash
git add test/fixtures/corpus test/integration/corpus_test.exs
git commit -m "test: AWS-authored task-definition corpus with golden comparisons"
```

---

### Task 14: Burrito release build

**Files:**
- Modify: `mix.exs` (release config exists from Task 1)
- Create: none new

- [ ] **Step 1: Build the release for the host platform only**

Run (macOS dev machine): `MIX_ENV=prod mix release ecs_task_def --overwrite 2>&1 | tail -20`
Expected: Burrito wraps the release and reports output binaries under `burrito_out/`.

Known macOS gotcha (see `~/.claude/knowledge-base/burrito-zig-macos26.md`): on macOS 26 the zig link step fails with all-libc `undefined symbol` errors because the macOS 26 SDK's `libSystem.tbd` drops plain `arm64-macos`. Fix: an `xcrun` shim earlier in PATH that redirects `--show-sdk-path` to an installed `MacOSX15.x.sdk`. If those errors appear, apply that shim and re-run.

To keep iteration fast, temporarily comment out all but the host target in `mix.exs` `releases/0` during this step; restore the full target list before committing.

- [ ] **Step 2: Smoke-test the binary**

Run:

```bash
BIN=$(ls burrito_out/ecs_task_def_macos_aarch64 2>/dev/null || ls burrito_out/* | head -1)
"$BIN" --help
"$BIN" generate 2>&1; echo "exit=$?"
tmpdir=$(mktemp -d)
"$BIN" init "$tmpdir" --vendor
ECR_REPO=repo IMAGE_TAG=tag "$BIN" generate "$tmpdir/mytask.pkl" -o "$tmpdir/task.json"
cat "$tmpdir/task.json" | head -5
```

Expected: help text; usage error with `exit=1`; scaffold + successful generate with the ✓ progress lines; JSON output. This proves the Application/argv wiring (`:start_cli` in prod) works end to end.

- [ ] **Step 3: Commit**

```bash
git add mix.exs
git commit -m "build: verified Burrito release build and binary smoke test"
```

---

### Task 15: CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-15]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4

      # Pin the action version: mise 2026.6.7 shipped no macOS build once
      # (knowledge-base/mise.md); the committed mise.lock pins tool versions.
      - uses: jdx/mise-action@v4
        with:
          version: 2026.7.0

      - name: Restore deps cache
        uses: actions/cache@v4
        with:
          path: |
            deps
            _build
          key: mix-${{ matrix.os }}-${{ hashFiles('mix.lock') }}

      - run: mix deps.get
      - run: mix compile --warnings-as-errors
      - run: mix test

      - name: Regen drift check (schema + generated Pkl module in sync with pin)
        run: mix ecs.regen_schema --check

      - name: check-jsonschema cross-validation of golden corpus
        run: |
          # pipx is preinstalled on GitHub runners and sidesteps PEP-668
          # externally-managed-environment errors that break plain pip installs.
          pipx install check-jsonschema
          check-jsonschema --schemafile priv/schema.json test/fixtures/corpus/*.golden.json
```

- [ ] **Step 2: Validate the YAML locally and push**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml')); print('yaml ok')"` (or `mise x python@latest -- …` if pyyaml is absent, `pip install --user pyyaml`).
Expected: `yaml ok`

```bash
git add .github/workflows/ci.yml
git commit -m "ci: test matrix (linux/macos) with mise toolchain, drift check, check-jsonschema cross-check"
git push origin main
```

Then run: `gh run watch --exit-status` (or `gh run list --limit 1` until complete)
Expected: green on both OSes. Fix forward anything red before proceeding (common first-run issues: pip PATH on macOS runners; `mise install` needing `MISE_EXPERIMENTAL` for a backend — consult knowledge-base/mise.md).

---

### Task 16: Pkl package metadata + release workflow

**Files:**
- Create: `pkl/PklProject`
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Create PklProject**

Create `pkl/PklProject`:

```pkl
amends "pkl:Project"

package {
  name = "ecs-task-def"
  baseUri = "package://pkg.pkl-lang.org/github.com/djgoku/aws-ecs-task-definition-generator/ecs-task-def"
  version = "0.1.0" // keep in lockstep with mix.exs version
  packageZipUrl = "https://github.com/djgoku/aws-ecs-task-definition-generator/releases/download/ecs-task-def@\(version)/ecs-task-def@\(version).zip"
  exclude { "PklProject" }
}
```

Run: `cd pkl && pkl project package && ls .out/ && cd ..`
Expected: `.out/ecs-task-def@0.1.0/` containing `ecs-task-def@0.1.0` (metadata JSON), `ecs-task-def@0.1.0.zip`, and `.sha256` checksum files. Add `pkl/.out/` to `.gitignore`.

- [ ] **Step 2: Write the release workflow**

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags:
      - "ecs-task-def@*"

permissions:
  contents: write

jobs:
  build-binaries:
    strategy:
      matrix:
        include:
          - os: ubuntu-latest
            targets: linux
          - os: macos-15 # NOT macos-26: its SDK breaks burrito/zig arm64 linking
            targets: macos
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v4
        with:
          version: 2026.7.0
      - run: mix deps.get
      - name: Build releases
        run: MIX_ENV=prod mix release ecs_task_def --overwrite
      - name: Upload binaries to the release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "${GITHUB_REF_NAME}" --verify-tag --title "${GITHUB_REF_NAME}" || true
          for bin in burrito_out/ecs_task_def_${{ matrix.targets }}_*; do
            name=$(basename "$bin" | sed 's/^ecs_task_def_/ecs-task-def-/')
            cp "$bin" "/tmp/$name"
            gh release upload "${GITHUB_REF_NAME}" "/tmp/$name" --clobber
          done

  pkl-package:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v4
        with:
          version: 2026.7.0
      - name: Package and upload the Pkl package artifacts
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          cd pkl && pkl project package && cd ..
          gh release create "${GITHUB_REF_NAME}" --verify-tag --title "${GITHUB_REF_NAME}" || true
          gh release upload "${GITHUB_REF_NAME}" pkl/.out/*/* --clobber
```

Notes for the implementer:
- Burrito cross-compiles both linux CPU targets from the ubuntu runner and both macos targets from the macos-15 runner; if a cross-target fails on a runner, restrict `releases/0` targets per-OS via an env var check rather than fighting the toolchain.
- The `gh release create … || true` on both jobs makes release creation race-safe (`gh release` semantics: create on existing exits 1 — knowledge-base/github-releases.md); `--verify-tag` guards against tag typos.
- The tag format `ecs-task-def@X.Y.Z` is load-bearing: the pkg.pkl-lang.org redirect resolves `…/releases/download/ecs-task-def@X.Y.Z/ecs-task-def@X.Y.Z` (validated in the design spec).

- [ ] **Step 3: Validate YAML, commit, and tag a 0.1.0 release when ready**

Run: `python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in ['.github/workflows/release.yml']]; print('yaml ok')"`
Expected: `yaml ok`

```bash
echo "pkl/.out/" >> .gitignore
git add pkl/PklProject .github/workflows/release.yml .gitignore
git commit -m "release: PklProject metadata and tag-driven release workflow (binaries + pkl package)"
```

When the user wants the first release: `git tag ecs-task-def@0.1.0 && git push origin ecs-task-def@0.1.0`, watch the workflow, then verify the package URL resolves:
`pkl eval -x 1 "package://pkg.pkl-lang.org/github.com/djgoku/aws-ecs-task-definition-generator/ecs-task-def@0.1.0#/EcsSchema.pkl"` — expected: evaluation error about required properties (proves fetch + parse worked), not a 404.

Also verify the default (non-vendor) scaffold end-to-end after the first release exists:

```bash
tmpdir=$(mktemp -d) && cd "$tmpdir"
ecs-task-def init
ECR_REPO=repo IMAGE_TAG=tag ecs-task-def generate mytask.pkl
```

Expected: JSON on stdout (first run fetches the package, later runs hit pkl's cache).

---

## Plan self-review notes (already applied)

- Spec coverage: every spec section maps to a task — CLI contract (11), .env grammar (3–4), shadow warning (4, 12), Unicode fix (5), atomic writes (6), preflight (7), stderr framing (8, 11), pinning + regen + drift (2, 9), init detail (10, 12), corpus + cross-check (13, 15), mise commit (1, 15), package/release/tag format (16), exit codes (11, 12).
- The `--vendor` amends line resolving relative to `mytask.pkl` is asserted by integration Task 12 test 1.
- Deliberately not in this plan (spec "Out of scope"): `--register`, YAML output, bundling pkl, hand-extending the generated module.
