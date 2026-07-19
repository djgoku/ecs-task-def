# Shared Release Build Task Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide one `mise run build` command that builds both CPU release binaries for the host OS locally and in GitHub Actions, including the macOS 26 SDK workaround.

**Architecture:** Keep target definitions and OS-to-target expansion in `mix.exs`. Put host detection, dependency fetching, production Mix settings, and the macOS-only `PATH` adjustment in mise; isolate the Zig/macOS SDK compatibility workaround in a narrowly scoped `bin/xcrun` shim; reduce GitHub Actions to invoking the same mise task.

**Tech Stack:** mise 2026.7.0, POSIX shell, Elixir 1.20.1-otp-29, Erlang/OTP 29.0.2, Burrito 1.5.0, Zig 0.15.2, GitHub Actions

## Global Constraints

- `mise run build` is the canonical local and CI release-binary command.
- Darwin builds both `macos_aarch64` and `macos_x86_64`; Linux builds both `linux_x86_64` and `linux_aarch64`.
- Generated release binaries remain under `burrito_out/`.
- The xcrun shim intercepts only macOS SDK-path queries and delegates every other invocation to `/usr/bin/xcrun`.
- The shim is temporary for Burrito 1.5.0/Zig 0.15.2 and must include an explicit removal condition.
- Preserve the existing uncommitted `conda:xz` and `aqua:ip7z/7zip` tool additions and their generated `mise.lock` entries; they are release-build prerequisites.
- Keep the workflow's exact-two-artifacts assertion.
- Do not move GitHub release creation or upload behavior into mise.

---

### Task 1: Canonical mise Build Task and macOS SDK Shim

**Files:**
- Create: `bin/xcrun`
- Modify: `mise.toml:1-9`
- Preserve: `mise.lock`

**Interfaces:**
- Consumes: `ECS_TASK_DEF_RELEASE_OS` values accepted by `EcsTaskDef.MixProject.burrito_targets/0`: `"macos"` or `"linux"`
- Produces: `mise run deps` and `mise run build`; two `burrito_out/ecs_task_def_<os>_*` binaries for the detected host OS

- [ ] **Step 1: Verify the build task does not yet exist**

Run:

```bash
mise task info build
```

Expected: nonzero exit with `Task not found: build`.

- [ ] **Step 2: Add the narrowly scoped xcrun shim**

Create `bin/xcrun`:

```bash
#!/bin/bash
# Build shim: works around the macOS 26 SDK + Zig 0.15.2 link failure in
# Burrito 1.5.0. The macOS 26 SDK's libSystem.tbd lacks the arm64-macos
# entries Zig needs, so redirect only macOS SDK-path queries to an installed
# macOS 14/15 SDK. Every other xcrun invocation uses the real tool.
#
# REMOVE-WHEN: Burrito supports a Zig version that links successfully against
# the macOS 26 SDK. Re-test `mise run build` without the bin/ PATH prepend.
set -euo pipefail

want_sdk_path=false
req_sdk=macosx
prev=
for arg in "$@"; do
  case "$arg" in
    --show-sdk-path) want_sdk_path=true ;;
    --sdk=*) req_sdk=${arg#--sdk=} ;;
  esac

  if [[ "$prev" == "--sdk" ]]; then
    req_sdk=$arg
  fi
  prev=$arg
done

if [[ "$want_sdk_path" == true && "$req_sdk" == macosx* ]]; then
  for candidate in \
    /Library/Developer/CommandLineTools/SDKs/MacOSX15*.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX14*.sdk \
    /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX15*.sdk \
    /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX14*.sdk; do
    if [[ -d "$candidate" ]]; then
      echo "$candidate"
      exit 0
    fi
  done

  echo "bin/xcrun: no MacOSX14/15 SDK found; Zig 0.15.2 will likely fail to link" >&2
fi

exec /usr/bin/xcrun "$@"
```

Make it executable:

```bash
chmod +x bin/xcrun
```

- [ ] **Step 3: Add the mise tasks without replacing existing tool changes**

Retain the existing `[tools]` entries, including:

```toml
"conda:xz" = "latest"
"aqua:ip7z/7zip" = "latest"
```

Append to `mise.toml`:

```toml
[tasks.deps]
description = "Fetch Hex dependencies"
run = "mix deps.get"

[tasks.build]
description = "Build both Burrito release binaries for the host OS"
depends = ["deps"]
run = """
set -eu

case "$(uname -s)" in
  Darwin)
    export ECS_TASK_DEF_RELEASE_OS=macos
    export PATH="$PWD/bin:$PATH"
    ;;
  Linux)
    export ECS_TASK_DEF_RELEASE_OS=linux
    ;;
  *)
    echo "build: unsupported host OS: $(uname -s) (expected Darwin or Linux)" >&2
    exit 1
    ;;
esac

MIX_ENV=prod mix release ecs_task_def --overwrite
"""
```

- [ ] **Step 4: Verify the task registration and SDK routing**

Run:

```bash
mise task info build
PATH="$PWD/bin:$PATH" xcrun --show-sdk-path
PATH="$PWD/bin:$PATH" xcrun --find clang
```

Expected:

- task info names `build`, its `deps` dependency, and its release command;
- the SDK query returns an installed `MacOSX14*.sdk` or `MacOSX15*.sdk`;
- the non-SDK query delegates successfully and returns the real clang path.

- [ ] **Step 5: Run the canonical build**

Run:

```bash
mise run build
```

Expected on this host: exit `0`; Burrito builds `macos_aarch64` and
`macos_x86_64` without unresolved Darwin symbols.

- [ ] **Step 6: Verify both macOS artifacts and smoke-test the native binary**

Run:

```bash
test -x burrito_out/ecs_task_def_macos_aarch64
test -x burrito_out/ecs_task_def_macos_x86_64
file burrito_out/ecs_task_def_macos_aarch64
file burrito_out/ecs_task_def_macos_x86_64
burrito_out/ecs_task_def_macos_aarch64 --help
```

Expected:

- both artifact checks exit `0`;
- `file` reports arm64 and x86_64 Mach-O executables respectively;
- the native binary prints CLI usage and exits `0`.

- [ ] **Step 7: Commit the build task**

Stage the task, shim, lockfile, and the already-present release dependencies:

```bash
git add bin/xcrun mise.toml mise.lock
git commit -m "build: add shared mise release task"
```

---

### Task 2: Thin Release Workflow and Canonical Documentation

**Files:**
- Modify: `.github/workflows/release.yml:21-25,67-72`
- Modify: `README.md:145-174`
- Modify: `docs/superpowers/plans/2026-07-18-shared-release-build-task.md`

**Interfaces:**
- Consumes: `mise run build` from Task 1 and the workflow matrix runner OS
- Produces: a GitHub Actions build step that uses the same command as local development while preserving release upload behavior

- [ ] **Step 1: Verify the workflow still contains duplicated build behavior**

Run:

```bash
rg -n 'ECS_TASK_DEF_RELEASE_OS|MIX_ENV=prod mix release' .github/workflows/release.yml
```

Expected: matches in the binary build step, proving the workflow has not yet
been migrated.

- [ ] **Step 2: Replace the workflow-specific release invocation**

Change the matrix to carry only runner names:

```yaml
matrix:
  os: [ubuntu-latest, macos-15]
runs-on: ${{ matrix.os }}
```

Remove the standalone `mix deps.get` step and replace the build step with:

```yaml
- name: Build releases (this OS's two CPU targets only)
  run: mise run build
```

Keep artifact validation OS-aware without duplicating the build selector:

```yaml
- name: Upload binaries to the release
  env:
    GH_TOKEN: ${{ github.token }}
  run: |
    set -euo pipefail
    shopt -s nullglob
    tag="${GITHUB_REF_NAME}"

    case "${RUNNER_OS}" in
      Linux) release_os=linux ;;
      macOS) release_os=macos ;;
      *)
        echo "::error::unsupported runner OS: ${RUNNER_OS}" >&2
        exit 1
        ;;
    esac

    bins=(burrito_out/ecs_task_def_"${release_os}"_*)
    if [ "${#bins[@]}" -ne 2 ]; then
      echo "::error::expected exactly 2 built binaries matching burrito_out/ecs_task_def_${release_os}_*, found ${#bins[@]}: ${bins[*]:-none}" >&2
      exit 1
    fi
```

Leave the subsequent release-create and upload loop unchanged.

- [ ] **Step 3: Make `mise run build` canonical in the README**

Replace the direct Mix release instructions with:

````markdown
Build both CPU release binaries for the host OS (output lands under
`burrito_out/`):

```console
$ mise run build
```

The same task runs in the release workflow. It fetches Hex dependencies,
selects both macOS or both Linux targets from the host OS, sets
`MIX_ENV=prod`, and uses `--overwrite`.

On macOS 26, the task prepends the repository's narrowly scoped `bin/xcrun`
shim so Zig 0.15.2 links against an installed macOS 14/15 SDK. Other xcrun
operations still use `/usr/bin/xcrun`. Remove this workaround after Burrito
supports a Zig version that links against the macOS 26 SDK.
````

- [ ] **Step 4: Verify workflow deduplication and YAML syntax**

Run:

```bash
test "$(rg -c 'mise run build' .github/workflows/release.yml)" -eq 1
! rg -n 'ECS_TASK_DEF_RELEASE_OS|MIX_ENV=prod mix release' .github/workflows/release.yml
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/release.yml"); puts "yaml ok"'
```

Expected: the count assertion exits `0`, the negative search finds no
workflow-owned build environment/command, and Ruby prints `yaml ok`.

- [ ] **Step 5: Run repository verification**

Run:

```bash
mise exec -- mix format --check-formatted
mise exec -- mix test
git diff --check
```

Expected: formatting and diff checks exit `0`; the complete ExUnit suite has
zero failures.

- [ ] **Step 6: Commit the workflow and documentation**

```bash
git add .github/workflows/release.yml README.md docs/superpowers/plans/2026-07-18-shared-release-build-task.md
git commit -m "ci: build releases through mise"
```
