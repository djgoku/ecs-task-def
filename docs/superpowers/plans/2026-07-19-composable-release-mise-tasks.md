# Composable Release Mise Tasks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the multiline shell blocks in `.github/workflows/release.yml` with composable mise tasks that behave identically in CI and local runs.

**Architecture:** Keep release logic in Bash-backed TOML tasks beside the existing `build` and `release-smoke` tasks. Put tag and artifact gates in safe mise dependencies, then invoke the mutating `release-ensure` sequentially from each publishing body only after those gates pass. Leave GitHub Actions responsible for orchestration and credentials.

**Tech Stack:** mise 2026.7.0, Bash 3.2+, Pkl 0.31.1, GitHub CLI, GitHub Actions, TOML, YAML

## Global Constraints

- Preserve the two-OS `ubuntu-latest`/`macos-15` release matrix.
- Preserve the `ecs-task-def@X.Y.Z` tag format and equality with both project versions.
- `RELEASE_TAG` is environment-only and keeps its full value for every `gh` command.
- Only tag validation strips `ecs-task-def@` into `X.Y.Z`.
- Preserve exact-two binary and exact-four Pkl artifact checks.
- Preserve race-safe create: create failure is accepted only when release view succeeds.
- Preserve binary prefix renaming and `gh release upload --clobber`.
- Keep `build` and `release-smoke` unchanged.
- Safe tasks never mutate GitHub; mutating tasks require `GH_TOKEN`.
- Artifact-count failures must occur before any `gh release create` call.
- Retain `::error::` prefixes for GitHub annotation behavior.
- Publishing never implicitly builds binaries or packages Pkl.

---

### Task 1: Safe Release Validation, Artifact Checks, and Pkl Packaging

**Files:**
- Modify: `mise.toml:92`

**Interfaces:**
- Consumes: `RELEASE_TAG`, `mix.exs`, `pkl/PklProject`, Pkl 0.31.1
- Produces: `release-validate-tag`, `release-check-binaries`, `release-check-pkl`, and `release-package-pkl`; four checked Pkl artifacts under `pkl/.out/*/*`

- [ ] **Step 1: Verify the tasks are initially absent**

Run:

```bash
mise task info release-validate-tag
mise task info release-check-binaries
mise task info release-check-pkl
mise task info release-package-pkl
```

Expected: all four commands exit nonzero with `Task not found`.

- [ ] **Step 2: Add the validation task**

Append to `mise.toml`:

```toml
[tasks.release-validate-tag]
description = "Validate the release tag against the Mix and Pkl project versions"
shell = "bash -c"
run = '''
set -euo pipefail

tag="${RELEASE_TAG:-}"
if [ -z "$tag" ]; then
  echo "::error::RELEASE_TAG is required (expected ecs-task-def@X.Y.Z)" >&2
  exit 1
fi

tag_version="${tag#ecs-task-def@}"
if [ "$tag_version" = "$tag" ]; then
  echo "::error::tag '$tag' does not match the required 'ecs-task-def@X.Y.Z' format" >&2
  exit 1
fi

mix_version="$(grep -m1 -E '^[[:space:]]*version:[[:space:]]*"' mix.exs | sed -E 's/.*"([^"]+)".*/\1/')"
pkl_version="$(grep -m1 -E 'version = "' pkl/PklProject | sed -E 's/.*"([^"]+)".*/\1/')"

if [ -z "$mix_version" ] || [ -z "$pkl_version" ]; then
  echo "::error::could not parse version from mix.exs ('$mix_version') or pkl/PklProject ('$pkl_version')" >&2
  exit 1
fi

if [ "$tag_version" != "$mix_version" ] || [ "$tag_version" != "$pkl_version" ]; then
  echo "::error::tag version '$tag_version' must match mix.exs version '$mix_version' and pkl/PklProject version '$pkl_version'" >&2
  exit 1
fi

echo "tag version $tag_version matches mix.exs and pkl/PklProject"
'''
```

- [ ] **Step 3: Exercise all validation outcomes**

Run:

```bash
RELEASE_TAG=ecs-task-def@0.1.0 mise run release-validate-tag
RELEASE_TAG=0.1.0 mise run release-validate-tag
RELEASE_TAG=ecs-task-def@9.9.9 mise run release-validate-tag
env -u RELEASE_TAG mise run release-validate-tag
```

Expected:

- the first command exits `0` and reports matching version `0.1.0`;
- the second exits nonzero with the required-format error;
- the third exits nonzero with all three compared versions;
- the fourth exits nonzero with the required-input error.

- [ ] **Step 4: Add the two safe artifact-check tasks**

Append to `mise.toml`:

```toml
[tasks.release-check-binaries]
description = "Require exactly two Burrito binaries for the host OS"
shell = "bash -c"
run = '''
set -euo pipefail
shopt -s nullglob

case "$(uname -s)" in
  Darwin) release_os=macos ;;
  Linux) release_os=linux ;;
  *)
    echo "::error::unsupported host OS: $(uname -s) (expected Darwin or Linux)" >&2
    exit 1
    ;;
esac

bins=(burrito_out/ecs_task_def_"${release_os}"_*)
if [ "${#bins[@]}" -ne 2 ]; then
  echo "::error::expected exactly 2 built binaries matching burrito_out/ecs_task_def_${release_os}_*, found ${#bins[@]}: ${bins[*]:-none}" >&2
  exit 1
fi

echo "found exactly 2 Burrito binaries for $release_os"
'''

[tasks.release-check-pkl]
description = "Require exactly four Pkl package artifacts"
shell = "bash -c"
run = '''
set -euo pipefail
shopt -s nullglob

assets=(pkl/.out/*/*)
if [ "${#assets[@]}" -ne 4 ]; then
  echo "::error::expected exactly 4 pkl package artifacts (metadata json + zip + their .sha256 sidecars), found ${#assets[@]}: ${assets[*]:-none}" >&2
  exit 1
fi

echo "found exactly 4 Pkl package artifacts"
'''
```

Neither task declares `GH_TOKEN`, calls `gh`, builds binaries, or packages Pkl.

- [ ] **Step 5: Add the Pkl packaging task**

Append to `mise.toml`:

```toml
[tasks.release-package-pkl]
description = "Package Pkl and require its four release artifacts"
shell = "bash -c"
run = '''
set -euo pipefail

(
  cd pkl
  pkl project package
)

mise run release-check-pkl
'''
```

- [ ] **Step 6: Verify the safe checks and Pkl packaging**

Run:

```bash
mise run build
mise run release-check-binaries
mise run release-package-pkl
mise run release-check-pkl
find pkl/.out -maxdepth 3 -type f -print | sort
```

Expected: the binary check finds exactly two existing host-OS Burrito artifacts; packaging exits `0`; the Pkl check passes; the listing contains exactly four files comprising metadata JSON, ZIP, and both SHA-256 sidecars.

- [ ] **Step 7: Format and commit the safe tasks**

Run:

```bash
tombi format mise.toml
tombi lint mise.toml
git diff --check
git add mise.toml
git commit -S -m "build: add release preparation tasks"
```

Expected: TOML checks pass and the signed commit contains only `mise.toml`.

---

### Task 2: Race-Safe Publishing Tasks and Fake GitHub Harness

**Files:**
- Modify: `mise.toml`
- Create: `test/support/fake_gh.sh`

**Interfaces:**
- Consumes: `release-validate-tag`, `release-check-binaries`, `release-check-pkl`, `RELEASE_TAG`, `GH_TOKEN`, built Burrito artifacts, packaged Pkl artifacts
- Produces: `release-ensure`, `release-publish-binaries`, `release-publish-pkl`; a recording fake `gh` controlled by `FAKE_GH_MODE`

- [ ] **Step 1: Verify publishing tasks are initially absent**

Run:

```bash
mise task info release-ensure
mise task info release-publish-binaries
mise task info release-publish-pkl
```

Expected: all three commands exit nonzero with `Task not found`.

- [ ] **Step 2: Add race-safe release creation**

Append to `mise.toml`:

```toml
[tasks.release-ensure]
description = "Create the GitHub release or confirm a concurrent job created it"
depends = ["release-validate-tag"]
shell = "bash -c"
run = '''
set -euo pipefail

if [ -z "${GH_TOKEN:-}" ]; then
  echo "::error::GH_TOKEN is required to create or inspect the GitHub release" >&2
  exit 1
fi

tag="${RELEASE_TAG:-}"
if ! gh release create "$tag" --verify-tag --title "$tag" \
     --notes "Automated release for $tag."; then
  if ! gh release view "$tag" >/dev/null 2>&1; then
    echo "::error::gh release create failed and no release exists for $tag (not a create-create race)" >&2
    exit 1
  fi
  echo "release $tag already exists (created by a concurrent release job); continuing"
fi
'''
```

- [ ] **Step 3: Add binary publishing**

Append to `mise.toml`:

```toml
[tasks.release-publish-binaries]
description = "Upload this host OS's two Burrito binaries to the GitHub release"
depends = ["release-validate-tag", "release-check-binaries"]
shell = "bash -c"
run = '''
set -euo pipefail
shopt -s nullglob

mise run release-ensure

tag="${RELEASE_TAG:-}"
case "$(uname -s)" in
  Darwin) release_os=macos ;;
  Linux) release_os=linux ;;
  *)
    echo "::error::unsupported host OS: $(uname -s) (expected Darwin or Linux)" >&2
    exit 1
    ;;
esac

bins=(burrito_out/ecs_task_def_"${release_os}"_*)
for bin in "${bins[@]}"; do
  name="$(basename "$bin" | sed 's/^ecs_task_def_/ecs-task-def-/')"
  cp "$bin" "/tmp/$name"
  gh release upload "$tag" "/tmp/$name" --clobber
done
'''
```

- [ ] **Step 4: Add Pkl publishing**

Append to `mise.toml`:

```toml
[tasks.release-publish-pkl]
description = "Upload the four Pkl package artifacts to the GitHub release"
depends = ["release-validate-tag", "release-check-pkl"]
shell = "bash -c"
run = '''
set -euo pipefail
shopt -s nullglob

mise run release-ensure

tag="${RELEASE_TAG:-}"
assets=(pkl/.out/*/*)
for asset in "${assets[@]}"; do
  gh release upload "$tag" "$asset" --clobber
done
'''
```

- [ ] **Step 5: Create the recording fake `gh`**

Create `test/support/fake_gh.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${FAKE_GH_LOG:?FAKE_GH_LOG is required}"
: "${FAKE_GH_MODE:?FAKE_GH_MODE is required}"

{
  printf '%q' "${1:-}"
  for arg in "${@:2}"; do
    printf ' %q' "$arg"
  done
  printf '\n'
} >>"$FAKE_GH_LOG"

if [ "${1:-}" != "release" ]; then
  exit 64
fi

case "${2:-}" in
  create)
    case "$FAKE_GH_MODE" in
      create-ok) exit 0 ;;
      create-race|create-fatal) exit 1 ;;
      *) exit 64 ;;
    esac
    ;;
  view)
    case "$FAKE_GH_MODE" in
      create-race) exit 0 ;;
      create-ok|create-fatal) exit 1 ;;
      *) exit 64 ;;
    esac
    ;;
  upload)
    exit 0
    ;;
  *)
    exit 64
    ;;
esac
```

Run:

```bash
chmod +x test/support/fake_gh.sh
```

- [ ] **Step 6: Build a disposable verification checkout**

Run:

```bash
verify_root="$(mktemp -d "${TMPDIR:-/tmp}/ecs-release-task-test.XXXXXX")"
mkdir -p "$verify_root/repo" "$verify_root/bin"
rsync -a \
  --exclude .git \
  --exclude deps \
  --exclude _build \
  --exclude burrito_out \
  --exclude 'pkl/.out' \
  ./ "$verify_root/repo/"
ln -s "$verify_root/repo/test/support/fake_gh.sh" "$verify_root/bin/gh"
cd "$verify_root/repo"

case "$(uname -s)" in
  Darwin) release_os=macos ;;
  Linux) release_os=linux ;;
esac

mkdir -p burrito_out pkl/.out/test
touch \
  "burrito_out/ecs_task_def_${release_os}_aarch64" \
  "burrito_out/ecs_task_def_${release_os}_x86_64" \
  pkl/.out/test/package.json \
  pkl/.out/test/package.zip \
  pkl/.out/test/package.json.sha256 \
  pkl/.out/test/package.zip.sha256

export PATH="$verify_root/bin:$PATH"
export GH_TOKEN=fake
export RELEASE_TAG=ecs-task-def@0.1.0
export FAKE_GH_LOG="$verify_root/gh.log"
```

Expected: all fixture paths exist in an isolated copy; the original checkout is untouched.

- [ ] **Step 7: Exercise all release creation outcomes**

Run:

```bash
: >"$FAKE_GH_LOG"
FAKE_GH_MODE=create-ok mise run release-ensure
rg -n '^release create ecs-task-def@0\.1\.0 --verify-tag --title ecs-task-def@0\.1\.0 ' "$FAKE_GH_LOG"

: >"$FAKE_GH_LOG"
FAKE_GH_MODE=create-race mise run release-ensure
rg -n '^release view ecs-task-def@0\.1\.0$' "$FAKE_GH_LOG"

: >"$FAKE_GH_LOG"
if FAKE_GH_MODE=create-fatal mise run release-ensure; then
  echo "release-ensure unexpectedly accepted a non-race failure" >&2
  exit 1
fi
rg -n '^release create |^release view ' "$FAKE_GH_LOG"
```

Expected: create-ok and create-race exit `0`; create-fatal exits nonzero after recording both create and view.

- [ ] **Step 8: Exercise both upload tasks**

Run:

```bash
: >"$FAKE_GH_LOG"
FAKE_GH_MODE=create-ok mise run release-publish-binaries
rg -n "release upload ecs-task-def@0\\.1\\.0 /tmp/ecs-task-def-${release_os}_(aarch64|x86_64) --clobber" "$FAKE_GH_LOG"
test "$(rg -c '^release upload ' "$FAKE_GH_LOG")" -eq 2

: >"$FAKE_GH_LOG"
FAKE_GH_MODE=create-ok mise run release-publish-pkl
test "$(rg -c '^release upload ecs-task-def@0\\.1\\.0 pkl/\\.out/test/.* --clobber$' "$FAKE_GH_LOG")" -eq 4
```

Expected: binary publishing records two renamed `/tmp/ecs-task-def-<os>_<arch>` uploads; Pkl publishing records four package artifact uploads.

- [ ] **Step 9: Verify both artifact-count failure gates**

Run:

```bash
touch "burrito_out/ecs_task_def_${release_os}_extra"
: >"$FAKE_GH_LOG"
if FAKE_GH_MODE=create-ok mise run release-publish-binaries; then
  echo "binary publishing unexpectedly accepted 3 artifacts" >&2
  exit 1
fi
test "$(rg -c '^release upload ' "$FAKE_GH_LOG" || true)" -eq 0
test "$(rg -c '^release create ' "$FAKE_GH_LOG" || true)" -eq 0

touch pkl/.out/test/extra.sha256
: >"$FAKE_GH_LOG"
if FAKE_GH_MODE=create-ok mise run release-publish-pkl; then
  echo "Pkl publishing unexpectedly accepted 5 artifacts" >&2
  exit 1
fi
test "$(rg -c '^release upload ' "$FAKE_GH_LOG" || true)" -eq 0
test "$(rg -c '^release create ' "$FAKE_GH_LOG" || true)" -eq 0
```

Expected: both publishing tasks exit nonzero from their safe artifact dependency and record neither release creation nor upload.

- [ ] **Step 10: Format and commit publishing**

Return to the original checkout, then run:

```bash
tombi format mise.toml
tombi lint mise.toml
git diff --check
git add mise.toml test/support/fake_gh.sh
git commit -S -m "build: add release publishing tasks"
```

Expected: the signed commit contains the three mutating/publishing tasks and executable fake `gh`.

---

### Task 3: Thin GitHub Release Workflow

**Files:**
- Modify: `.github/workflows/release.yml:8-181`

**Interfaces:**
- Consumes: all seven new release tasks plus existing `build` and `release-smoke`
- Produces: a release workflow with no multiline shell blocks

- [ ] **Step 1: Verify the workflow still owns the shell logic**

Run:

```bash
rg -n 'run: \\||tag_version=|gh release create|gh release upload|pkl project package' .github/workflows/release.yml
```

Expected: matches for all three multiline blocks and their release commands.

- [ ] **Step 2: Add the canonical workflow tag environment**

Add after `permissions`:

```yaml
env:
  RELEASE_TAG: ${{ github.ref_name }}
```

- [ ] **Step 3: Replace the binary job shell blocks**

Replace the tag-validation block with:

```yaml
- name: Validate tag matches mix.exs and pkl/PklProject versions
  run: mise run release-validate-tag
```

Keep the existing build and smoke steps unchanged. Replace the binary upload block with:

```yaml
- name: Upload binaries to the release
  env:
    GH_TOKEN: ${{ github.token }}
  run: mise run release-publish-binaries
```

- [ ] **Step 4: Replace the Pkl job shell blocks**

Replace its duplicated validation block with:

```yaml
- name: Validate tag matches mix.exs and pkl/PklProject versions
  run: mise run release-validate-tag
```

Replace package/upload with two steps:

```yaml
- name: Package the Pkl release artifacts
  run: mise run release-package-pkl

- name: Upload the Pkl package artifacts
  env:
    GH_TOKEN: ${{ github.token }}
  run: mise run release-publish-pkl
```

- [ ] **Step 5: Verify the workflow is thin and valid**

Run:

```bash
if rg -n 'run: \\|' .github/workflows/release.yml; then
  echo "release workflow still contains multiline shell" >&2
  exit 1
fi

ruby -e 'require "yaml"; YAML.load_file(".github/workflows/release.yml", aliases: true)'
rg -n 'RELEASE_TAG|mise run (release-validate-tag|build|release-smoke|release-publish-binaries|release-package-pkl|release-publish-pkl)' .github/workflows/release.yml
```

Expected: no multiline `run` blocks; YAML parses; all required task invocations and the top-level tag mapping appear.

- [ ] **Step 6: Commit the workflow refactor**

Run:

```bash
git diff --check
git add .github/workflows/release.yml
git commit -S -m "ci: use composable mise release tasks"
```

Expected: the signed commit changes only the release workflow.

---

### Task 4: Full Repository Verification

**Files:**
- Verify: `mise.toml`
- Verify: `.github/workflows/release.yml`
- Verify: `test/support/fake_gh.sh`

**Interfaces:**
- Consumes: Tasks 1-3
- Produces: fresh evidence that the complete refactor is ready for review

- [ ] **Step 1: Verify task discovery and configuration**

Run:

```bash
mise tasks ls
tombi lint mise.toml
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/release.yml", aliases: true)'
```

Expected: all seven release tasks are listed; TOML and YAML parse successfully.

- [ ] **Step 2: Run project verification**

Run:

```bash
mise x -- mix format --check-formatted
mise x -- mix compile --warnings-as-errors
mise x -- mix test
git diff --check
git status -sb
```

Expected: formatting and compilation pass; all 98 tests pass; no unstaged implementation changes remain after the three task commits.

- [ ] **Step 3: Request code review**

Review the three implementation commits against:

```text
docs/superpowers/specs/2026-07-19-release-mise-tasks-design.md
```

Expected: no unresolved Critical or Important findings before publishing the branch.
