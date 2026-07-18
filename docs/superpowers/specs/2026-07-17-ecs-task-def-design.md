# ecs-task-def — design

Date: 2026-07-17
Status: approved (brainstorm session, all decisions validated below; revised
same day after external review — see Deliverables for the target-state/current-state
distinction: the repo currently contains only this spec, everything named
below is a deliverable to build)

## What it is

`ecs-task-def` is an Elixir CLI, released as a single self-contained binary via
Burrito, that turns a typed [Pkl](https://pkl-lang.org) file into a validated
Amazon ECS task-definition JSON file. It is a pure generator: it never talks to
AWS. Users register the output themselves
(`aws ecs register-task-definition --cli-input-json file://taskdef.json`).

"Validated" means conformance to the awslabs JSON schema (plus Pkl's type
checks) — not a guarantee that AWS accepts the definition. Runtime constraints
the schema does not encode (e.g. valid Fargate cpu/memory combinations) can
still be rejected at registration time.

Design priorities, in order:

1. **Great errors.** Every failure states location, what is wrong, and how to
   fix it. Missing environment variables are always an error, never silently
   empty.
2. **Start small, build up.** v1 covers the full task-definition surface via
   schema validation, but keeps the tool surface minimal (two commands).
3. **Single-binary story**, with one documented external *tool* requirement:
   the `pkl` CLI on PATH. (Default `init` templates additionally need network
   on the first eval to fetch the schema package — pkl caches it afterward;
   `init --vendor` is the fully offline/air-gapped path. See Distribution.)

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
- `ex_json_schema` 0.11.5 loads and enforces this exact schema (spike-proven,
  see Resolved risk below — including the one gotcha and its fix).
- `pkg.pkl-lang.org` mechanically redirects
  `github.com/<owner>/<repo>/<name>@<ver>` package URIs to that repo's GitHub
  release assets, so publishing a Pkl package requires only attaching
  `pkl project package` output to a normal GitHub release.

## Resolved risk: Unicode regex patterns (spike completed 2026-07-17)

The awslabs schema contains exactly **two** patterns using Unicode property
escapes (`\p{L}` etc.): `tags[].key` and `tags[].value` (identical pattern).
Spike results (Elixir 1.20.1/OTP 29, ex_json_schema 0.11.5, real schema +
generated JSON):

- `ex_json_schema` resolves and validates the draft-07 schema correctly, with
  usable error tuples (`{"Type mismatch. Expected String but got Integer.", "#/cpu"}`).
- **Gotcha found and fixed:** it compiles `pattern` regexes without Unicode
  mode, so `\p{L}` matched only ASCII letters and wrongly rejected legal
  non-ASCII tag keys (e.g. `"Ünïcode-Key_1"`). Prepending `(*UTF)(*UCP)` to
  the pattern string fixes matching even under a flag-less `Regex.compile!/1`
  (PCRE start-of-pattern verbs override compile options; proven directly).
- **Decision:** the embedded `priv/schema.json` stays **pristine** (byte-for-
  byte the pinned awslabs file — required so ECMA-engine cross-checkers like
  check-jsonschema can consume it directly in CI). The Validator applies the
  `(*UTF)(*UCP)` prefix **at load time** to any pattern containing a Unicode
  property escape (`\p{`) — currently exactly the two `tags` patterns, and
  automatically any the schema grows later. Full pattern enforcement is
  retained — no weakened validation, no fallback needed.
- `check-jsonschema` (0.36.2) handles this schema as-is — its default regex
  mode uses an ECMA-compatible engine (the same handling demonstrated against
  this schema in
  [check-jsonschema PR #512](https://github.com/python-jsonschema/check-jsonschema/pull/512),
  which was closed unmerged, so its ECS fixtures live only on that PR
  branch). Proven locally against our generated output (valid → ok,
  invalid → correct per-field errors), so the CI cross-check stands. Raw
  python-jsonschema (which fails on these patterns) is not used anywhere.

## User experience

```console
$ ecs-task-def init                    # scaffold starter mytask.pkl (amends the versioned package URL)
$ ecs-task-def init --vendor           # same, but copies EcsSchema.pkl into the repo; amends the local file

$ ecs-task-def generate mytask.pkl --env-file .env.production -o taskdef.json
✓ pkl 0.31.1 found
✓ evaluated mytask.pkl
✓ validated against ECS schema v1.4.0 (awslabs@2abcd3f)
wrote taskdef.json
```

(The displayed schema version comes from the pinned awslabs schema's own
description, and the short SHA is the pinned awslabs commit — both derive
from the single pin; see Distribution.)

### CLI contract

Both commands validate their parsed options against a per-command
NimbleOptions schema (see Architecture); `--help` text derives from the same
schemas via `NimbleOptions.docs/1`, and its first line includes the
ecs-task-def version plus the pinned schema identity (version + short SHA),
so `ecs-task-def --help` is enough to answer "what am I running?".

**`ecs-task-def generate INPUT.pkl [flags]`**

| Flag | Alias | Type | Default | Meaning |
|---|---|---|---|---|
| `--output` | `-o` | path | stdout | Where the JSON goes |
| `--env-file` | — | path | none | `.env` file merged under the process env |

Exactly one INPUT argument is required. Progress/warning lines go to stderr;
the JSON document is the only thing ever written to stdout (when `-o` is not
given), so piping is safe.

**`ecs-task-def init [DIR] [flags]`**

| Flag | Type | Default | Meaning |
|---|---|---|---|
| `--vendor` | boolean | false | Also write `EcsSchema.pkl` locally; `amends` points at it instead of the package URL |

DIR defaults to the current directory. Files written: `mytask.pkl` (starter
template), plus `EcsSchema.pkl` with `--vendor`. `init` **never overwrites**:
if any target file already exists, it exits 6 listing the conflicting paths
and writes nothing (no partial scaffold).

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
- Exact `.env` grammar (kept deliberately small; anything outside it is a
  line-numbered error, per the great-errors priority):
  - One `KEY=VALUE` per line. An optional `export ` prefix is accepted and
    ignored. CRLF line endings and a leading UTF-8 BOM are tolerated.
  - `KEY` must match `[A-Za-z_][A-Za-z0-9_]*` (after trimming whitespace).
  - `VALUE` is everything after the **first** `=` (so values may contain `=`),
    with surrounding whitespace trimmed. Empty values (`KEY=`) are legal. If
    the trimmed value is wrapped in matching single or double quotes, one
    outer quote pair is stripped; no escape-sequence processing, no multiline
    values, no inline comments (a trailing `# ...` is part of the value —
    quote-strip aside, values are verbatim).
  - Full-line comments (first non-whitespace char `#`) and blank lines are
    skipped.
  - Duplicate keys within the file: **last one wins**, with a stderr warning
    naming the key and both line numbers.
  - A line with no `=`, or an invalid key: error `file:line: reason`, exit 3.
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

- The awslabs schema is **pinned by commit SHA** in the regen mix task; the
  pinned `schema.json` is committed to this repo (it is also what gets
  embedded in `priv/` for the validator). The user-visible schema version
  string (e.g. "v1.4.0") is parsed from the schema's own description field —
  one source, no drift.
- `pkl/EcsSchema.pkl` is generated by the codegen and **committed to this
  repo** — the single source of truth for the Pkl side.
- `mix ecs.regen_schema` re-runs the codegen against the pinned awslabs
  schema (bumping the pin is an explicit edit). It regenerates **both**
  artifacts together — the committed `schema.json` and `EcsSchema.pkl` — and
  CI fails if rerunning the task produces a diff, so the two can never be
  out of sync with each other or with the pin.
- Each GitHub release attaches: Burrito binaries per platform, plus the Pkl
  package artifacts (`pkl project package` output: metadata JSON + zip). That
  makes `package://pkg.pkl-lang.org/github.com/djgoku/aws-ecs-task-definition-generator/ecs-task-def@X.Y.Z#/EcsSchema.pkl`
  resolve with zero hosting infrastructure. Note: the pkg.pkl-lang.org
  redirect maps to `releases/download/<name>@<ver>/…`, so the GitHub release
  **tag must be `ecs-task-def@X.Y.Z`** (validated 2026-07-17). pkl caches
  downloaded packages, so evals are offline after first fetch.
- `init` behavior in detail:
  - **Default:** writes `mytask.pkl` whose first line is
    `amends "package://…/ecs-task-def@X.Y.Z#/EcsSchema.pkl"`, where `X.Y.Z`
    is the running binary's own version — the scaffold is always pinned to
    the schema the binary was built and tested with, never "latest". The
    first `pkl eval` fetches the package over HTTPS (GitHub release via the
    pkg.pkl-lang.org redirect) and caches it in pkl's package cache
    (`~/.pkl/cache`); subsequent evals are offline. Checksums in the package
    metadata make the fetch tamper-evident.
  - **`--vendor`:** additionally writes the binary's embedded copy of
    `EcsSchema.pkl` next to `mytask.pkl`, and the `amends` line is the
    relative path `"EcsSchema.pkl"` instead of the package URL. No network,
    ever; the schema is a visible, diffable, committed file in the user's
    repo. This is the path for air-gapped hosts, hermetic CI, or teams that
    want schema changes to show up in their own code review.
  - **Upgrading** (either mode): rerun `init` with a newer binary in a clean
    location (or delete the scaffolded files first — `init` never
    overwrites), or hand-edit: bump the version in the `amends` URL, or
    replace the vendored `EcsSchema.pkl`. The scaffold contains no other
    version-coupled content.

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
5. **Write** — to `-o` file or stdout. Output is written only on full
   success. File writes are atomic: write to a temp file in the target's
   directory, then rename over the destination (replacing any previous
   version only as the final step); on any failure the temp file is removed
   and an existing destination file is left untouched.

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
| 6 | cannot write output / `init` target exists | path + OS reason; for `init`, the list of conflicting files |

Principle: pkl's errors are already excellent — frame them (one-line header
naming the failed stage), never rewrite them. Our own errors imitate the same
style: location first, then what, then how to fix.

## Testing

- **Unit** (pure, no pkl): `EnvFile` parser (full grammar matrix: quotes,
  `export `, empty values, values containing `=`, duplicate keys, CRLF/BOM,
  malformed lines), `Validator` error formatting, CLI arg parsing, env merge
  precedence + shadow warning (differing values warn, identical values don't,
  values never appear in the message), and the `(*UTF)(*UCP)` pattern
  preprocessing (a non-ASCII tag key like `"Ünïcode-Key_1"` must validate; a
  genuinely illegal tag key must still fail).
- **Integration** (require real `pkl` on PATH; tagged to skip with a notice
  when absent): golden-file tests — fixture `.pkl` in, expected JSON out —
  plus one test per error-table row asserting exit code and message shape.
- **Real-world fixture corpus** (researched 2026-07-17): port AWS-authored
  task definitions into Pkl fixtures whose generated JSON is golden-compared
  against the originals and schema-validated. Sources:
  - [aws-samples/aws-containers-task-definitions](https://github.com/aws-samples/aws-containers-task-definitions)
    (active repo; nginx, tomcat, consul, gunicorn, jetty, kibana, wildfly —
    each with `*_ec2.json` and `*_fargate.json` variants).
  - The AWS developer guide's
    [example task definitions page](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/example_task_definitions.html).
  - The negative/positive fixtures from
    [check-jsonschema PR #512](https://github.com/python-jsonschema/check-jsonschema/pull/512)
    (`fargate.json`, `invalid.json`) as additional seeds (PR branch only —
    copy, don't reference).
  This corpus exercises far more of the schema surface (EC2 + Fargate,
  volumes, log configs, health checks) than hand-written minimal fixtures.
- **CI cross-check**: every golden JSON is also validated with
  `check-jsonschema`; two independent validator implementations agreeing
  guards against bugs in either.
- CI: Linux + macOS; toolchain (erlang, elixir, pkl, zig-for-Burrito) comes
  from the repo's committed `mise.toml` + `mise.lock` — CI and local dev
  install identical pinned versions via mise. Plus the regen-task drift check
  (see Distribution).

## Deliverables

The repo currently contains only this spec. Implementation must produce:

1. Elixir mix project with the six modules listed under Architecture; deps:
   `ex_json_schema`, `nimble_options`, Burrito.
2. Committed generated artifacts: `pkl/EcsSchema.pkl` + the pinned
   `schema.json`, with `mix ecs.regen_schema` and its CI drift check.
3. Embedded `priv/` assets: the pristine pinned schema (`(*UTF)(*UCP)`
   preprocessing happens at Validator load time — see Resolved risk),
   `EcsSchema.pkl` copy for `--vendor`, starter template.
4. `PklProject` metadata so `pkl project package` produces the package
   artifacts; release workflow attaching Burrito binaries per platform plus
   the package artifacts, on releases tagged `ecs-task-def@X.Y.Z`.
5. Test suite + CI as specified under Testing, including the ported
   real-world fixture corpus.
6. Committed `mise.toml` + `mise.lock` pinning the full toolchain (erlang,
   elixir, pkl, zig for Burrito) for both local dev and CI.

## Out of scope (v1)

- Calling AWS APIs (`--register`), YAML output, diffing/watching task
  definitions.
- Hand-extending the generated Pkl module — schema validation backstops
  anything the generated types miss.
- Bundling or auto-downloading the `pkl` binary.
