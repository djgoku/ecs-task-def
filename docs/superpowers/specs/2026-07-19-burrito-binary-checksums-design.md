# Burrito Binary Checksum Assets

## Goal

Publish a SHA-256 sidecar alongside every Burrito binary so users can verify a
download without relying on GitHub's release UI or API.

The sidecars provide download-integrity checking, not signed authenticity. A
party able to replace a release binary could also replace its checksum; signing
release artifacts is outside this change's scope.

Keep the project and Pkl package versions at `0.1.0`. After the implementation
is merged, replace the existing `ecs-task-def@0.1.0` release and tag so the
release workflow rebuilds the original version with the complete asset set.

## Release Task Design

Extend `release-publish-binaries` in `mise.toml`. The task continues to accept
the exact two host-OS binaries validated by `release-check-binaries` and rename
them from:

```text
ecs_task_def_<os>_<arch>
```

to:

```text
ecs-task-def-<os>_<arch>
```

The task creates a private temporary directory with `mktemp -d`, then registers
a trap that removes it on every subsequent exit path. Registering the trap only
after `mktemp -d` succeeds avoids referencing an unset path under
`set -u`. The task copies both renamed binaries into that directory, then runs
the macOS- and Linux-compatible checksum command once per binary from inside
the directory:

```sh
shasum -a 256 "$name" > "$name.sha256"
```

The explicit filename prevents a later invocation from hashing a sidecar
created by an earlier invocation. Each checksum file contains the standard
digest and basename:

```text
<64 lowercase hexadecimal characters>  ecs-task-def-<os>_<arch>
```

The resulting binary assets are:

```text
ecs-task-def-linux_aarch64
ecs-task-def-linux_aarch64.sha256
ecs-task-def-linux_x86_64
ecs-task-def-linux_x86_64.sha256
ecs-task-def-macos_aarch64
ecs-task-def-macos_aarch64.sha256
ecs-task-def-macos_x86_64
ecs-task-def-macos_x86_64.sha256
```

Each host job prepares two sidecars. The workflow's existing Ubuntu and macOS
matrix is what produces all four platform sidecars; no single host test builds
or publishes all four.

Once both binaries and both checksum files for the current host have been
prepared successfully, the task runs `release-ensure` and uploads all four
files with `gh release upload --clobber`. Preparing everything before
`release-ensure` guarantees that copy or checksum failures make no GitHub
mutation.

The GitHub workflow continues to call only
`mise run release-publish-binaries`; no checksum shell commands are added to
the workflow.

## Failure Handling

The task uses `set -euo pipefail`, so temporary-directory creation, copying,
checksum generation, release creation, or upload failures stop the task. The
cleanup trap still removes prepared assets.

`release-check-binaries` remains the source-artifact gate. Checksum sidecars
are derived publishing artifacts, so they do not become inputs to that task
and do not change its exact-two-file contract.

If `shasum` is unavailable, the task reports a focused `::error::` message
before preparing assets or mutating GitHub. The implementation does not add a
new mise tool solely for checksumming because `shasum` is available on the
supported GitHub macOS and Ubuntu runners.

## Automated Verification

Update `test/release_tasks_test.exs` and its fake GitHub harness to prove:

- the binary publisher uploads the two exact renamed binaries and their two
  `.sha256` sidecars for the host operating system;
- each captured sidecar contains the SHA-256 digest of the captured binary and
  names that binary by basename;
- a checksum-command failure occurs before `release create` or
  `release upload`;
- the existing unexpected, missing, wrong-name, directory, symlink, and
  non-executable source-artifact cases still fail before GitHub mutation; and
- the Pkl publishing behavior remains unchanged.

The checksum-failure test writes a failing `shasum` executable into only that
test's isolated `bin_dir`, which already precedes the system `PATH`. Other
tests retain the real `shasum`, so the happy path exercises actual digest
generation without a new mode or repository tool dependency.

The temporary directory removes the need for the current fake `cp` command and
its stable-`/tmp` protection comment. Tests will instead use the real `cp`
against the private temporary directory. The fake `gh` upload branch treats its
fourth argument as the asset path and copies it to
`$FAKE_GH_UPLOAD_DIR/$(basename "$4")`. `run_task` supplies a fixture-owned
`FAKE_GH_UPLOAD_DIR`. Because fake `gh` captures the file synchronously during
each upload, the copied binary and sidecar remain available for assertions
after the publishing task's cleanup trap removes its temporary directory.

Run formatting, compilation with warnings treated as errors, the focused
release-task tests, and the complete ExUnit suite. Inspect the workflow and
mise task list to confirm GitHub Actions still delegates publishing to the
composable task. Update `README.org` with a short
`shasum -a 256 -c <file>.sha256` example so users know how to verify a
download.

## Replacing Release 0.1.0

Release replacement is an explicit post-merge operation, not part of the mise
task or GitHub workflow. After the checksum implementation is on `main`:

1. delete the existing GitHub release for `ecs-task-def@0.1.0`;
2. delete the existing remote and local `ecs-task-def@0.1.0` tag;
3. create the same tag at the updated `main` commit; and
4. push the tag to trigger a fresh release workflow.

The replacement must not change `mix.exs`, `pkl/PklProject`, or the tag's
version. Deleting the release and moving the tag are external mutations and
require explicit approval immediately before execution.

## Alternatives Considered

GNU `sha256sum` has a familiar verification format, but it is not installed by
default on macOS. Adding it as a tool dependency would make a small release
feature more fragile than using the supported `shasum` command.

GitHub records a digest for uploaded assets, but that digest is not a
downloadable sidecar and does not satisfy users who want a conventional local
verification file.

Generating checksums beside `burrito_out` would avoid a temporary copy, but
the released binary names differ from the Burrito output names. A private
temporary directory ensures the sidecar records the actual downloadable
filename, avoids stable `/tmp` collisions, and leaves the build output
unchanged.
