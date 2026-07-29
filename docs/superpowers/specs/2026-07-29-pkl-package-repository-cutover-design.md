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

## Scope

Work occurs in an isolated Git worktree created from `main` on
`codex/fix-pkl-package-repository`.

Active source changes are limited to:

- `mix.exs`: bump the application version from 0.1.0 to 0.1.1.
- `pkl/PklProject`: bump the package version to 0.1.1 and replace both
  `baseUri` and `packageZipUrl` with canonical `djgoku/ecs-task-def` values.
- `lib/ecs_task_def/scaffold.ex`: generate the canonical package URI.
- `test/ecs_task_def/scaffold_test.exs`: add regression coverage tying the
  Pkl project coordinate to scaffold output.
- `README.org`: update the active GitHub Releases link and both active Pkl
  package examples.

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

Before changing active source, add a test that expects the canonical base URI
in both `pkl/PklProject` and a freshly scaffolded `mytask.pkl`. The test must
also require the canonical GitHub Releases prefix in `packageZipUrl`.

The test is expected to fail against `main`, proving that it detects the
existing drift. After the focused source edits, the same test and the complete
ExUnit suite must pass.

This directly covers the defect class: two independently maintained package
coordinates drifting apart.

## Package Validation

Validation uses the repository's release tasks wherever possible:

1. Run formatting, focused tests, and the complete test suite.
2. Run `mise run release-package-pkl` to exercise the same default packaging
   and publish-check path used by CI, recording whether the existing 0.1.0
   publication affects the new 0.1.1 coordinate.
3. If network policy prevents the publish check, record that limitation and
   run local packaging with `pkl project package --skip-publish-check`.
4. Run `mise run release-check-pkl`.
5. Require exactly the four versioned 0.1.1 artifacts.
6. Inspect the generated metadata and require the canonical `packageUri`,
   canonical `packageZipUrl`, version 0.1.1, and a matching ZIP checksum.
7. Verify both checksum sidecars and require `EcsSchema.pkl` at the archive
   root.
8. Record the new ZIP SHA-256 and compare it with the previous local 0.1.0
   checksum
   `9ecd70ea98753c5c47ebf25e8b4990b0daec2c97b480f846ddc05932c76726f8`
   as release-decision evidence only.

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
