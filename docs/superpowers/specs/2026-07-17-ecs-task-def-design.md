# ecs-task-def — design

Date: 2026-07-17
Status: approved (brainstorm session, all decisions validated below)

## What it is

`ecs-task-def` is an Elixir CLI, released as a single self-contained binary via
Burrito, that turns a typed [Pkl](https://pkl-lang.org) file into a validated
Amazon ECS task-definition JSON file. It is a pure generator: it never talks to
AWS. Users register the output themselves
(`aws ecs register-task-definition --cli-input-json file://taskdef.json`).

Design priorities, in order:

1. **Great errors.** Every failure states location, what is wrong, and how to
   fix it. Missing environment variables are always an error, never silently
   empty.
2. **Start small, build up.** v1 covers the full task-definition surface via
   schema validation, but keeps the tool surface minimal (two commands).
3. **Single-binary story**, with one documented external requirement: the
   `pkl` CLI on PATH.

## Validated foundations (tested 2026-07-17, see ~/.claude/knowledge-base/pkl.md)

- Pkl bindings in every language spawn the `pkl` CLI as a child process; there
  is no embeddable evaluator. Therefore the tool requires `pkl` on PATH
  (user decision: no bundling, no auto-download).
- The official pkl-pantry codegen `org.json_schema.contrib@1.2.0` converts the
  [awslabs amazon-ecs-intellisense-schema](https://github.com/awslabs/amazon-ecs-intellisense-schema)
  (draft-07, 93 KB, all 17 top-level task-definition properties) into a
  1,415-line typed `EcsSchema.pkl` with enums, optionality, and AWS doc
  comments. (`@1.0.0` is broken on Pkl 0.31.1 — pin `@1.2.0+`.)
- A 20-line user file amending that module produced correct task-definition
  JSON; a typo'd field and a missing `read("env:VAR")` both failed at eval
  with file:line + object-path errors.
- `ex_json_schema` 0.11.5 supports draft-07 (README; passes the official JSON
  Schema test suite).
- `pkg.pkl-lang.org` mechanically redirects
  `github.com/<owner>/<repo>/<name>@<ver>` package URIs to that repo's GitHub
  release assets, so publishing a Pkl package requires only attaching
  `pkl project package` output to a normal GitHub release.

## Open risk (spike first in implementation)

The awslabs schema uses Unicode property escapes (`\p{L}`) in regex patterns.
Python's `re` cannot compile them (proven: python-jsonschema fails on the
schema itself). Erlang's PCRE-based regex should handle them, but this is
**unvalidated** for `ex_json_schema`. Implementation task 1 is a spike proving
`ex_json_schema` loads and enforces this schema, patterns included. Fallback
if it fails: preprocess patterns or drop `pattern` enforcement for affected
fields (schema validation minus those patterns still beats no validation).

## User experience

```console
$ ecs-task-def init                    # scaffold starter mytask.pkl (amends the versioned package URL)
$ ecs-task-def init --vendor           # same, but copies EcsSchema.pkl into the repo; amends the local file

$ ecs-task-def generate mytask.pkl --env-file .env.production -o taskdef.json
✓ pkl 0.31.1 found
✓ evaluated mytask.pkl
✓ validated against ECS schema v1.4.0
wrote taskdef.json
```

A user file looks like:

```pkl
amends "package://pkg.pkl-lang.org/github.com/djgoku/aws-ecs-task-definition-generator/ecs-task-def@1.0.0#/EcsSchema.pkl"

family = "web-app"
networkMode = "awsvpc"
requiresCompatibilities { "FARGATE" }
cpu = "256"
memory = "512"

containerDefinitions {
  new {
    name = "web"
    image = "\(read("env:ECR_REPO")):\(read("env:IMAGE_TAG"))"
    essential = true
    portMappings { new { containerPort = 8080; protocol = "tcp" } }
  }
}
```

Because the file `amends` the typed module, typos and wrong types fail at
`pkl eval` with the user's file and line number — before any JSON exists.

### Environment variables and .env files

- Templates read variables with Pkl-native `read("env:NAME")`.
- `--env-file FILE` parses plain `KEY=VALUE` lines (`#` comments, blank lines
  allowed). Malformed lines error with `file:line: reason`.
- Merge rule: **process environment wins over the env file** (12-factor: the
  file supplies defaults; the real environment overrides). This matches the
  dotenv-family default (node dotenv, python-dotenv, ruby dotenv all defer to
  existing environment variables unless an explicit override flag is passed).
- **Shadow warning:** if a variable is set in both the env file and the
  process environment **with different values**, emit a warning to stderr —
  naming the variable and the winner, never printing the values (they may be
  secrets): `warning: IMAGE_TAG is set in both the environment and
  .env.production with different values; using the environment value`.
  Identical values warn nothing. Precedence is unaffected.
- The merged set is passed to the spawned `pkl` process. A referenced-but-unset
  variable fails eval with pkl's `Cannot find resource 'env:NAME'` error,
  carrying template file:line and the object path (e.g.
  `at mytask#containerDefinitions[#1].image`). No extra machinery needed to
  satisfy "unreplaced variables are an error".

## Distribution of the schema module

- `pkl/EcsSchema.pkl` is generated by the codegen and **committed to this
  repo** — the single source of truth.
- `mix ecs.regen_schema` re-runs the codegen against the awslabs schema when
  AWS updates it.
- Each GitHub release attaches: Burrito binaries per platform, plus the Pkl
  package artifacts (`pkl project package` output: metadata JSON + zip). That
  makes `package://pkg.pkl-lang.org/github.com/djgoku/aws-ecs-task-definition-generator/ecs-task-def@X.Y.Z#/EcsSchema.pkl`
  resolve with zero hosting infrastructure. Note: the pkg.pkl-lang.org
  redirect maps to `releases/download/<name>@<ver>/…`, so the GitHub release
  **tag must be `ecs-task-def@X.Y.Z`** (validated 2026-07-17). pkl caches
  downloaded packages, so evals are offline after first fetch.
- `init` scaffolds the package-URL `amends` line by default (pinned to the
  binary's own version); `init --vendor` writes the embedded copy of
  `EcsSchema.pkl` into the user's project and points `amends` at it, for
  air-gapped or fully pinned setups.

## Architecture

Elixir mix project; Burrito release. Runtime dependencies: `ex_json_schema`,
`nimble_options` (and Burrito itself). CLI options flow: stdlib `OptionParser`
turns argv into a keyword list (nimble_options does not parse argv), then each
command declares a `NimbleOptions` schema its options are validated against —
one place defining types, defaults, and docs per command. NimbleOptions
validation errors are translated into the CLI error style (location, what,
how to fix) rather than surfaced raw.

Components, each with one job and independently testable:

| Module | Job |
|---|---|
| `EcsTaskDef.CLI` | argv parsing, dispatch, all user-facing output, exit codes |
| `EcsTaskDef.Preflight` | find `pkl` on PATH; enforce minimum version |
| `EcsTaskDef.EnvFile` | parse `.env` → map; line-numbered errors |
| `EcsTaskDef.Pkl` | spawn `pkl eval -f json` with merged env; capture stdout/stderr separately |
| `EcsTaskDef.Validator` | embedded awslabs schema + ex_json_schema; errors → `path: message` lines |
| `EcsTaskDef.Scaffold` | `init` templates (starter pkl; vendored schema copy) |

Assets embedded in `priv/`: the awslabs JSON schema (for the validator), the
generated `EcsSchema.pkl` (for `--vendor`), and the starter template.

## Data flow (`generate`)

1. **Preflight** — locate `pkl`, check `pkl --version` against the pinned
   minimum (the version the schema/codegen is tested against). Fail early,
   never mid-pipeline.
2. **Env assembly** — parse `--env-file` if given; merge under process env.
3. **Eval** — spawn `pkl eval -f json <input>` with merged env; capture stdout
   (JSON) and stderr (diagnostics) separately.
4. **Decode + validate** — parse JSON; validate against the embedded schema;
   collect **all** violations, not just the first.
5. **Write** — to `-o` file or stdout. Output is written only on full success;
   no partial/invalid file is ever left behind.

## Error handling

Every failure mode has a distinct exit code and a message that says what is
wrong and what to do:

| Exit | Failure | Message behavior |
|---|---|---|
| 0 | success | progress lines to stderr, JSON to stdout/file |
| 1 | usage error (unknown flag/command) | usage + suggestion ("did you mean --output?") |
| 2 | `pkl` missing or too old | install hint (brew/mise) + required minimum version |
| 3 | env file missing/malformed | `path:line: reason` |
| 4 | pkl eval failed | one-line stage header, then pkl's stderr passed through untouched (it already carries file:line + object path; missing env vars land here) |
| 5 | schema validation failed | one line per violation, `containerDefinitions[0].cpu: expected integer, got "256"`, plus a count |
| 6 | cannot write output | path + OS reason |

Principle: pkl's errors are already excellent — frame them (one-line header
naming the failed stage), never rewrite them. Our own errors imitate the same
style: location first, then what, then how to fix.

## Testing

- **Unit** (pure, no pkl): `EnvFile` parser, `Validator` error formatting,
  CLI arg parsing, env merge precedence + shadow warning (differing values
  warn, identical values don't, values never appear in the message).
- **Integration** (require real `pkl` on PATH; tagged to skip with a notice
  when absent): golden-file tests — fixture `.pkl` in, expected JSON out —
  plus one test per error-table row asserting exit code and message shape.
- **CI cross-check**: every golden JSON is also validated with
  `check-jsonschema`; two independent validator implementations agreeing
  guards against bugs in either.
- **Spike first**: prove `ex_json_schema` handles the schema's `\p{L}`
  patterns (see Open risk).
- CI: Linux + macOS, `pkl` installed via mise.

## Out of scope (v1)

- Calling AWS APIs (`--register`), YAML output, diffing/watching task
  definitions.
- Hand-extending the generated Pkl module — schema validation backstops
  anything the generated types miss.
- Bundling or auto-downloading the `pkl` binary.
