# Composable Release Mise Tasks

## Goal

Move the reusable shell logic out of `.github/workflows/release.yml` and into
composable mise tasks so release validation, packaging, and artifact checks run
the same way locally and in GitHub Actions.

Keep GitHub Actions responsible only for the tag trigger, job matrix, tool
installation, token injection, and invocation of named mise tasks.

## Task Design

Add the following tasks to `mise.toml`, following the existing inline `build`
and `release-smoke` task style:

- `release-validate-tag` validates `RELEASE_TAG` against the required
  `ecs-task-def@X.Y.Z` format and requires the tag version to equal both the Mix
  project version and `pkl/PklProject` version. It strips the prefix only into a
  local `tag_version` used for those comparisons.
- `release-package-pkl` runs `pkl project package` from `pkl/` and requires
  the safe `release-check-pkl` task to accept exactly four output artifacts:
  the metadata JSON, package ZIP, and their two SHA-256 sidecars.
- `release-check-binaries` derives `linux` or `macos` from `uname -s` and
  requires exactly two Burrito binaries for that operating system. It does not
  require `GH_TOKEN` or mutate GitHub.
- `release-check-pkl` requires exactly four Pkl package artifacts and does not
  require `GH_TOKEN` or mutate GitHub.
- `release-ensure` depends on tag validation and performs the existing
  race-safe GitHub release creation. A failed `gh release create` is accepted
  only when `gh release view` proves another concurrent job created the same
  release.
- `release-publish-binaries` depends on tag validation and
  `release-check-binaries`. After both safe dependencies pass, its body runs
  `release-ensure`, converts binary names from `ecs_task_def_*` to
  `ecs-task-def-*`, and uploads them with `--clobber`.
- `release-publish-pkl` depends on tag validation and `release-check-pkl`.
  After both safe dependencies pass, its body runs `release-ensure` and uploads
  all four artifacts with `--clobber`.

Keep the existing `build` and `release-smoke` tasks unchanged. Publishing tasks
do not implicitly build binaries or package Pkl, so the safe preparation steps
remain explicit and independently runnable. A local caller must run `build`
before `release-publish-binaries`, and must run `release-package-pkl` before
`release-publish-pkl`; otherwise the publishing task fails at its exact artifact
count gate.

## Inputs and Side Effects

`RELEASE_TAG` is the canonical, environment-only tag input for validation and
publishing tasks. It always retains the full `ecs-task-def@X.Y.Z` form when
passed to `gh`; only `release-validate-tag` derives the stripped `X.Y.Z` value
for version comparisons. No task accepts the tag as a positional argument.

GitHub Actions sets the full tag once at workflow scope:

```yaml
env:
  RELEASE_TAG: ${{ github.ref_name }}
```

Local callers use the same interface:

```sh
RELEASE_TAG=ecs-task-def@0.1.0 mise run release-validate-tag
```

The validation and Pkl packaging tasks do not mutate GitHub. Only
`release-ensure`, `release-publish-binaries`, and `release-publish-pkl` require
`GH_TOKEN` and make GitHub changes. Missing inputs, unsupported hosts, parse
failures, unexpected artifact counts, and non-race `gh` failures remain fatal
with focused messages. Keep the existing `::error::` prefixes in task failures
to preserve GitHub annotation behavior; they are harmless when printed locally.
The publishing tasks invoke the mutating `release-ensure` sequentially from
their bodies, after their safe dependencies have passed. This preserves the
current guarantee that an artifact-count failure cannot create an empty GitHub
release.

## Workflow Shape

The workflow declares the top-level `RELEASE_TAG` environment mapping shown
above. The binary matrix job will:

1. install the mise toolchain;
2. run `mise run release-validate-tag`;
3. run the existing `mise run build`;
4. run the existing `mise run release-smoke`; and
5. run `mise run release-publish-binaries` with `GH_TOKEN`.

The Pkl package job will:

1. install the mise toolchain;
2. run `mise run release-validate-tag`;
3. run `mise run release-package-pkl`; and
4. run `mise run release-publish-pkl` with `GH_TOKEN`.

The workflow retains the two-OS matrix, concurrency policy, permissions, and
non-strict mise installation rationale. Its multiline shell blocks are removed.
Calling `release-validate-tag` as its own workflow step and again transitively
through `release-ensure` is an intentional, idempotent recheck across separate
mise invocations.

## Knowledge-Base Updates

Refresh `~/.claude/knowledge-base/apple-container.md` with the validated
Apple Container 1.1.0 release and the reproduced service/CLI upgrade mismatch:

- mise upgraded the installed aqua package from 1.0.0 to 1.1.0 while the
  already-running launchd service remained on 1.0.0;
- `container system status` exposed the stale, deleted 1.0.0 `installRoot`;
- container boots stalled before guest execution and produced no `stdio.log`;
- explicitly stopping and starting the service with the selected 1.1.0 mise
  tool aligned the CLI, service, `vminit`, and kernel components; and
- a minimal Ubuntu `uname -a` plus the project’s full Linux regeneration check
  proved the repair.

Record the proof with the claims:

- `gh release view 1.1.0 --repo apple/container` reported the official 1.1.0
  release published on 2026-07-06;
- before repair, `mise where aqua:apple/container` selected 1.1.0 while
  `container --version` and `container system status` reported 1.0.0, and status
  named the removed
  `~/.local/share/mise/installs/aqua-apple-container/1.0.0/Payload/` install
  root;
- the stalled container had no `stdio.log`, proving the guest command never
  started;
- after
  `mise x aqua:apple/container@1.1.0 -- container system stop` followed by
  `container system start` through the same explicit mise tool, both CLI and
  API server reported 1.1.0 with the 1.1.0 install root;
- `container run --rm --arch arm64 ubuntu:24.04 uname -a` exited successfully;
  and
- an official Elixir 1.20/OTP 29 image run through Apple Container completed
  `mix ecs.regen_schema --check` with `regen check: all artifacts up to date`.

Correct the installation guidance: Apple publishes a signed installer, while
the aqua/mise package is also a validated installation path sharing the same
Apple Container data directory.

Add a short cross-reference to `mise.md` explaining that upgrading a
service-backed aqua tool does not restart an already-running service. Update
`index.md` so its Apple Container summary names 1.1.0 and the restart
requirement.

## Verification

- Confirm all new tasks appear in `mise tasks ls`.
- Exercise `release-validate-tag` with the valid project version, an invalid
  prefix, and a mismatched version.
- Run `release-package-pkl` and confirm its exact-four-artifact check.
- Exercise release creation and both publishing tasks against the fake `gh`
  harness described below so command construction, concurrent-create handling,
  renaming, and artifact selection are verified without mutating GitHub.
- Confirm `.github/workflows/release.yml` contains no multiline `run: |` shell
  blocks and parses as valid YAML.
- Run TOML formatting/checking, Mix formatting, warnings-as-errors compilation,
  and the complete ExUnit suite.
- Scan the three knowledge-base files for stale “latest = 1.0.0” claims and
  verify that every new operational claim includes the observed evidence.

### Fake `gh` Harness

Run publishing verification in a disposable copy of the repository with
`RELEASE_TAG=ecs-task-def@0.1.0`, matching the current versions in `mix.exs` and
`pkl/PklProject`. Prepend a temporary directory containing a recording fake
`gh` executable to `PATH`.

The fake accepts a mode environment variable and records every argument vector.
Exercise all three `release-ensure` outcomes:

1. `create-ok`: `gh release create` exits zero;
2. `create-race`: create exits nonzero and `gh release view` exits zero; and
3. `create-fatal`: both create and view exit nonzero, and the mise task must
   fail.

To reach upload behavior, create exactly two disposable
`burrito_out/ecs_task_def_<host-os>_*` binary fixtures and exactly four
`pkl/.out/*/*` package fixtures. Verify the fake recorded the full
`ecs-task-def@0.1.0` tag, both renamed `ecs-task-def-<host-os>_*` binary upload
paths, all four Pkl artifact paths, and `--clobber`. Also run each task with an
extra artifact and confirm its exact-count gate fails with zero `release create`
and zero `release upload` calls.

## Alternatives Considered

File-backed mise tasks would keep `mise.toml` shorter, but introduce several
new scripts and shared-helper boundaries for a modest amount of release logic.
A single monolithic release task would minimize workflow steps but make safe
local validation inseparable from GitHub mutation. Composable inline tasks fit
the repository’s existing pattern while preserving clear side-effect
boundaries.

Making publish tasks depend directly on `release-ensure` was also rejected.
Mise runs dependencies before the task body, so that dependency graph could
create an empty GitHub release before artifact-count validation fails. The
chosen design keeps the checks as safe dependencies and invokes
`release-ensure` sequentially only after those gates pass.
