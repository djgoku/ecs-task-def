# Shared Release Build Task

## Problem

The documented local release command assumes `mix` is already on `PATH`, while
GitHub Actions gets that behavior from `jdx/mise-action`. On this macOS 26
development host, running the command through mise reaches Burrito but Zig
0.15.2 then links against the macOS 26 SDK and fails with unresolved Darwin
symbols. The release workflow avoids that SDK by using a macOS 15 runner, but
the build command and environment setup remain duplicated in workflow YAML.

Local and CI release builds need one canonical entry point that selects both
CPU targets for the current operating system and applies the macOS 26 SDK
workaround where necessary.

## Design

### Canonical build interface

Add `mise run build` as the release-binary build interface for developers and
GitHub Actions. The task will:

1. depend on a `deps` task that runs `mix deps.get`;
2. detect the host with `uname -s`;
3. map `Darwin` to `ECS_TASK_DEF_RELEASE_OS=macos` and `Linux` to
   `ECS_TASK_DEF_RELEASE_OS=linux`;
4. fail with a clear unsupported-host message for any other value;
5. prepend the repository's `bin/` directory to `PATH` on macOS; and
6. run `MIX_ENV=prod mix release ecs_task_def --overwrite`.

The existing `burrito_targets/0` selection remains responsible for turning the
OS value into both CPU targets. A local macOS build therefore produces
`ecs_task_def_macos_aarch64` and `ecs_task_def_macos_x86_64`; the Linux CI job
produces the corresponding two Linux binaries.

### macOS SDK compatibility

Add a repository-local `bin/xcrun` shim based on the proven implementation in
the sibling `vzbeam` project. It intercepts only macOS
`xcrun --show-sdk-path` requests and returns the first installed macOS 15 or 14
SDK. Every other invocation delegates to `/usr/bin/xcrun`.

This is a temporary compatibility boundary for Burrito 1.5.0 and its required
Zig 0.15.2. If no compatible SDK is installed, the shim emits a focused warning
and delegates to the real `xcrun`; Burrito then fails normally. The comments
will include a removal condition: re-test and remove the shim when Burrito
supports a Zig version that links successfully against macOS 26 SDKs.

### GitHub Actions

Keep the existing two-OS matrix and artifact-count checks. Remove the
workflow-specific `ECS_TASK_DEF_RELEASE_OS` environment assignment and replace
the hardcoded Mix release command with:

```sh
mise run build
```

The workflow remains responsible for installing mise tools and uploading
artifacts. The mise task owns dependency fetching, host target selection, SDK
compatibility, and the release command.

### Documentation

Make `mise run build` the README's canonical release-build command. Explain
that it builds both CPU architectures for the host OS, matches the GitHub
Actions job, and automatically uses a compatible installed SDK on macOS 26.

## Verification

- Confirm the task is registered by mise.
- Run `mise run build` on this macOS 26 host.
- Assert that both macOS artifacts exist and have the expected Mach-O
  architectures.
- Smoke-test the native aarch64 binary with `--help`.
- Run formatting and the complete ExUnit suite.
- Parse the updated release workflow as YAML.
- Retain the workflow's exact-two-artifacts assertion as the Linux/macOS CI
  guard.
