# ecs-task-def

A CLI that turns a typed [Pkl](https://pkl-lang.org) file into a validated
Amazon ECS task-definition JSON file. It is a pure generator: it never talks
to AWS. Register the output yourself, e.g.

```console
$ aws ecs register-task-definition --cli-input-json file://taskdef.json
```

Every generated document is validated against the awslabs
[amazon-ecs-intellisense-schema](https://github.com/awslabs/amazon-ecs-intellisense-schema)
(plus Pkl's own type checks) before it is written anywhere. "Validated" means
schema conformance, not a guarantee AWS will accept it — some runtime
constraints (e.g. valid Fargate cpu/memory combinations) aren't encoded in
the schema and can still be rejected at registration time.

## Installation

`ecs-task-def` ships as a single self-contained binary (via
[Burrito](https://github.com/burrito-elixir/burrito)) for macOS and Linux,
built by the release workflow in this repo. **No release has been published
yet** — once one is, download the binary for your platform from this repo's
[GitHub Releases](https://github.com/djgoku/aws-ecs-task-definition-generator/releases)
page and put it on your `PATH`. Until then, run it from source (see
Contributing below).

### Prerequisite: the Pkl CLI

`ecs-task-def` shells out to the `pkl` binary — it isn't bundled or
auto-downloaded. Install `pkl` **0.31.1 or newer**:

```console
$ mise use --global pkl@0.31.1
# or
$ brew install pkl
```

`ecs-task-def` checks for `pkl` on `PATH` and its version before doing
anything else, and fails fast with an install/upgrade hint if it's missing
or too old.

## Usage

### `ecs-task-def init [DIR] [--vendor]`

Scaffolds a starter `mytask.pkl` in `DIR` (defaults to the current
directory).

**Until the first tagged release exists, use `--vendor`.** It additionally
writes a local `EcsSchema.pkl` next to `mytask.pkl`, which `amends` that
file instead of a package URL — fully offline, no network fetch, and it
works today with no dependency on a published release:

```console
$ ecs-task-def init --vendor
created ./mytask.pkl
created ./EcsSchema.pkl
```

Plain `init` (no `--vendor`) instead makes `mytask.pkl` `amends` the
versioned package URL
`package://pkg.pkl-lang.org/github.com/djgoku/aws-ecs-task-definition-generator/ecs-task-def@X.Y.Z#/EcsSchema.pkl`,
where `X.Y.Z` is the running binary's version. That scaffold is created
successfully right now, but the subsequent `generate` only succeeds once a
matching `ecs-task-def@X.Y.Z` release has been published (see Releasing
below) — until then `pkl eval` fails fetching the package zip over HTTPS
(currently a 404, since no release exists yet). Once a release is published,
the first `generate` fetches the schema over HTTPS and pkl caches it locally
(offline after that):

```console
$ ecs-task-def init
created ./mytask.pkl
next: set your env vars and run `ecs-task-def generate ./mytask.pkl`
```

`--vendor` remains useful after the first release too, for air-gapped hosts
or hermetic CI that shouldn't depend on network access.

`init` never overwrites: if any target file already exists it exits 6,
lists the conflicting paths, and writes nothing.

### `ecs-task-def generate INPUT.pkl [--output|-o PATH] [--env-file PATH]`

Evaluates `INPUT.pkl` and validates the result against the ECS schema:

```console
$ ecs-task-def generate mytask.pkl --env-file .env.production -o taskdef.json
✓ pkl 0.31.1 found
✓ evaluated mytask.pkl
✓ validated against ECS schema v1.4.0 (awslabs@39fae90)
wrote taskdef.json
```

Without `-o`/`--output`, the JSON document is written to **stdout** and
everything else (progress lines, warnings, errors) goes to **stderr**, so
piping is always safe:

```console
$ ecs-task-def generate mytask.pkl > taskdef.json
```

### `.env` files and environment precedence

`--env-file PATH` parses plain `KEY=VALUE` lines (`#` comments and blank
lines allowed; an optional `export ` prefix is accepted and ignored) and
merges them as defaults **under** the real process environment — the process
environment always wins, matching the usual dotenv convention. If a variable
is set in both places with *different* values, `ecs-task-def` warns on
stderr naming the variable and which value won, without ever printing either
value (they may be secrets):

```
warning: IMAGE_TAG is set in both the environment and .env.production with different values; using the environment value
```

Identical values in both places warn nothing.

### Help

```console
$ ecs-task-def --help
$ ecs-task-def generate --help
$ ecs-task-def init --help
```

Any of these print full usage (including the running binary's version and
the pinned ECS schema version/commit) and exit 0.

## Exit codes

| Exit | Meaning |
|---|---|
| 0 | success |
| 1 | usage error (unknown command/flag, missing/extra arguments) |
| 2 | `pkl` not found on `PATH`, or older than the required minimum |
| 3 | `--env-file` missing or malformed |
| 4 | `pkl eval` failed (bad template, unset `read("env:...")`, etc.) |
| 5 | generated JSON failed schema validation |
| 6 | couldn't write output, or `init` target files already exist |

## Contributing

Toolchain versions (Erlang, Elixir, Pkl, Zig for Burrito) are pinned in
`mise.toml`/`mise.lock`:

```console
$ mise install
$ mix deps.get
$ mix test
```

Check the vendored schema and generated `pkl/EcsSchema.pkl` are still in
sync with the pinned upstream schema:

```console
$ mix ecs.regen_schema --check
```

Build release binaries (output lands under `burrito_out/`). Left unset,
`ECS_TASK_DEF_RELEASE_OS` builds **all four** Burrito targets (both CPU
architectures, both macOS and Linux) in one `mix release` — it does not
limit the build to your local machine:

```console
$ MIX_ENV=prod mix release ecs_task_def --overwrite
```

Set `ECS_TASK_DEF_RELEASE_OS=linux` or `=macos` to build only that OS's two
CPU targets, matching what the release workflow's per-OS jobs do. The macOS
targets need a Zig link path against an SDK with an `arm64-macos` slice;
macOS 26's SDK ships only `arm64e-macos` and breaks that link, so the
release workflow builds on `macos-15`, not `macos-26`.

CI (`.github/workflows/ci.yml`) runs the same test suite and regen check on
Linux and macOS, plus a `check-jsonschema` cross-validation of the golden
fixture corpus.

### Releasing

Pushing a tag matching `ecs-task-def@X.Y.Z` (must match the version in
`mix.exs`) triggers the release workflow, which builds per-platform Burrito
binaries and packages `pkl/EcsSchema.pkl` for the
`package://pkg.pkl-lang.org/github.com/djgoku/aws-ecs-task-definition-generator/ecs-task-def@X.Y.Z`
coordinate that scaffolded (non-`--vendor`) `mytask.pkl` files `amends`.
