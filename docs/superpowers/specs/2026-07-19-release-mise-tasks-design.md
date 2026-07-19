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
  project version and `pkl/PklProject` version.
- `release-package-pkl` runs `pkl project package` from `pkl/` and requires
  exactly four output artifacts: the metadata JSON, package ZIP, and their two
  SHA-256 sidecars.
- `release-ensure` depends on tag validation and performs the existing
  race-safe GitHub release creation. A failed `gh release create` is accepted
  only when `gh release view` proves another concurrent job created the same
  release.
- `release-publish-binaries` depends on `release-ensure`, derives `linux` or
  `macos` from `uname -s`, requires exactly two Burrito binaries for that
  operating system, converts their names from `ecs_task_def_*` to
  `ecs-task-def-*`, and uploads them with `--clobber`.
- `release-publish-pkl` depends on `release-ensure`, rechecks that exactly four
  package artifacts exist, and uploads them with `--clobber`.

Keep the existing `build` and `release-smoke` tasks unchanged. Publishing tasks
do not implicitly build binaries or package Pkl, so the safe preparation steps
remain explicit and independently runnable.

## Inputs and Side Effects

`RELEASE_TAG` is the canonical tag input for validation and publishing tasks.
GitHub Actions sets it from `${{ github.ref_name }}` at workflow scope. Local
callers use the same interface:

```sh
RELEASE_TAG=ecs-task-def@0.1.0 mise run release-validate-tag
```

The validation and Pkl packaging tasks do not mutate GitHub. Only
`release-ensure`, `release-publish-binaries`, and `release-publish-pkl` require
`GH_TOKEN` and make GitHub changes. Missing inputs, unsupported hosts, parse
failures, unexpected artifact counts, and non-race `gh` failures remain fatal
with focused messages.

## Workflow Shape

The binary matrix job will:

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
- Exercise release creation and both publishing tasks against a fake `gh`
  executable so command construction, concurrent-create handling, renaming,
  and artifact selection are verified without mutating GitHub.
- Confirm `.github/workflows/release.yml` contains no multiline `run: |` shell
  blocks and parses as valid YAML.
- Run TOML formatting/checking, Mix formatting, warnings-as-errors compilation,
  and the complete ExUnit suite.
- Scan the three knowledge-base files for stale “latest = 1.0.0” claims and
  verify that every new operational claim includes the observed evidence.

## Alternatives Considered

File-backed mise tasks would keep `mise.toml` shorter, but introduce several
new scripts and shared-helper boundaries for a modest amount of release logic.
A single monolithic release task would minimize workflow steps but make safe
local validation inseparable from GitHub mutation. Composable inline tasks fit
the repository’s existing pattern while preserving clear side-effect
boundaries.
