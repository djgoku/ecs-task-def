# Pkl Package Repository Cutover Design

## Goal

Publish-ready source for `ecs-task-def` 0.1.1 must use
`djgoku/ecs-task-def` as the canonical GitHub repository everywhere active
code, package metadata, generated configuration, and user documentation refer
to the project.

This change prepares and validates the 0.1.1 package locally. It does not
create or move a tag, create or edit a GitHub release, upload assets, or alter
the existing 0.1.0 release.

## Root Cause

The published 0.1.0 Pkl metadata can be resolved through the canonical
`package://pkg.pkl-lang.org/github.com/djgoku/ecs-task-def/...` coordinate, but
its embedded `packageZipUrl` still names
`djgoku/aws-ecs-task-definition-generator`. Pkl follows that metadata value and
receives a 404 for the ZIP.

The same stale package coordinate is compiled into the 0.1.0 executable's
scaffold generator, so replacing 0.1.0 metadata alone would not repair
`ecs-task-def init`. Version 0.1.1 will correct both the metadata and the
generated `amends` URI.

## Preconditions

The isolated worktree is on `codex/fix-pkl-package-repository`, created from
`main`, and its `origin` is:

```text
git@github.com:djgoku/ecs-task-def.git
```

The observed 0.1.0 reproduction is:

```console
$ pkl download-package \
    "package://pkg.pkl-lang.org/github.com/djgoku/ecs-task-def/ecs-task-def@0.1.0"
Received unexpected status code `404` when making request `GET https://github.com/djgoku/aws-ecs-task-definition-generator/releases/download/ecs-task-def@0.1.0/ecs-task-def@0.1.0.zip`.
```

This proves that the canonical package coordinate resolves its metadata, but
that metadata sends Pkl to the stale repository for the archive.

Package validation starts with `pkl/.out/` absent or empty. The old 0.1.0
package must not be regenerated into that directory; comparisons use the
recorded checksum below so the exact-four-artifacts gate remains unambiguous.

## Scope

Work occurs in an isolated Git worktree created from `main` on
`codex/fix-pkl-package-repository`.

Active source changes are limited to:

- `mix.exs`: bump the application version from 0.1.0 to 0.1.1.
- `pkl/PklProject`: bump the package version to 0.1.1 and replace both
  `baseUri` and `packageZipUrl` with canonical `djgoku/ecs-task-def` values.
- `lib/ecs_task_def/scaffold.ex`: generate the canonical package URI.
- `test/ecs_task_def/scaffold_test.exs`: update the existing stale `amends`
  assertion and add regression coverage tying the Pkl project coordinate to
  scaffold output.
- `test/release_tasks_test.exs`: derive the fixture version and release tag
  from the application version instead of pinning 0.1.0, preserving positive
  version-lockstep coverage across future releases.
- `README.org`: update all three active sites: the GitHub Releases link and
  both Pkl package examples.

Historical implementation records under `docs/superpowers/` remain unchanged.
No unrelated dependencies, tools, release tasks, workflows, or generated
schema content change.

## Canonical Values

The Pkl package base URI is:

```text
package://pkg.pkl-lang.org/github.com/djgoku/ecs-task-def/ecs-task-def
```

For version 0.1.1, the package ZIP URL is:

```text
https://github.com/djgoku/ecs-task-def/releases/download/ecs-task-def@0.1.1/ecs-task-def@0.1.1.zip
```

The application version in `mix.exs` and package version in `pkl/PklProject`
must remain equal.

## Regression Strategy

Before changing active source, add a test that:

- reads `pkl/PklProject` from the repository root;
- requires its `baseUri` and `packageZipUrl` to match the canonical literals;
- parses `baseUri` from that file and requires a freshly scaffolded
  `mytask.pkl` to use the same value, rather than comparing both sources with
  independent duplicate literals; and
- requires the Pkl project version to equal the running application's version.

From `test/ecs_task_def/scaffold_test.exs`, the repository root is
`Path.expand("../..", __DIR__)`. The test only reads repository files and uses
its existing private temporary directory, so the module remains safe with
`async: true`.

Against `main`, the new coupling test must fail while the existing stale
`amends` assertion still passes. After the source fix, update that existing
assertion to the canonical URI; both tests and the complete ExUnit suite must
then pass.

In `test/release_tasks_test.exs`, derive `@version` from
`Mix.Project.config()[:version]` and construct `@release_tag` from that value.
The existing success-path release-task tests then continue to prove that the
Mix and Pkl versions match, while the negative artifact tests still reach the
specific validations they are intended to exercise.

This directly covers the defect class: two independently maintained package
coordinates or release versions drifting apart.

## Package Validation

Validation uses the repository's release tasks wherever possible:

1. Confirm `pkl/.out/` is absent or empty, then run formatting, focused tests,
   and the complete test suite. All commands must exit 0.
2. Run `mise run release-package-pkl` to exercise the same default packaging
   and publish-check path used by CI. Success requires exit 0 and
   `release-check-pkl` reporting exactly four 0.1.1 artifacts.
3. Before relying on a fallback, confirm `--skip-publish-check` is supported
   with `pkl project package --help`. If network policy alone prevents the
   default publish check, record the exact error as an unvalidated CI-path gap,
   then run `(cd pkl && pkl project package --skip-publish-check)`.
4. Run `mise run release-check-pkl`.
5. Require exactly the four versioned 0.1.1 artifacts.
6. Inspect the generated metadata and require the canonical `packageUri`,
   canonical `packageZipUrl`, version 0.1.1, and a matching ZIP checksum.
7. Verify both checksum sidecars and require `EcsSchema.pkl` at the archive
   root.
8. Record the new ZIP SHA-256 and compare it with the previous local 0.1.0
   checksum
   `9ecd70ea98753c5c47ebf25e8b4990b0daec2c97b480f846ddc05932c76726f8`
   as release-decision evidence. Because `PklProject` is excluded from the
   archive and `EcsSchema.pkl` is unchanged, the archived payload is expected
   to remain identical. A differing ZIP checksum therefore indicates either
   non-deterministic archive metadata or an unintended content change and must
   be explained before proceeding.

A successful local package proves the source and artifact relationships. A
true `pkl download-package` end-to-end test remains a post-publication gate
because the 0.1.1 metadata and ZIP do not exist at their HTTPS locations until
the release is published.

## Release Boundary

This branch stops at publish-ready, locally verified source. After 0.1.1 is
published, verify:

```bash
pkl download-package \
  --cache-dir "$(mktemp -d)" \
  "package://pkg.pkl-lang.org/github.com/djgoku/ecs-task-def/ecs-task-def@0.1.1"
```

Only after that succeeds will the project decide whether to annotate, delete,
or otherwise handle the broken 0.1.0 release. That follow-up is explicitly
outside this change.
