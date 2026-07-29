# Burrito, Zig, and macOS 26 Focused Cutover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade release builds to Burrito 1.6.0 and Zig 0.16.0, prove they link directly against the macOS 26 SDK, remove the obsolete SDK shim, and run active macOS GitHub Actions jobs on `macos-26`.

**Architecture:** Preserve the existing release target selection, artifact names, and publishing tasks. First update only the Burrito and Zig pins and prove a direct macOS 26 build without the shim in `PATH`; then remove the compatibility layer and stale active documentation; finally migrate both workflow matrices and run the complete local verification gate.

**Tech Stack:** Elixir 1.20.1 / Erlang/OTP 29.0.2, Burrito 1.6.0, Zig 0.16.0, mise 2026.7.0, GitHub Actions, macOS 26, Org documentation

## Global Constraints

- Keep the approved `{:burrito, "~> 1.6"}` constraint, but require it to
  resolve to exactly Burrito 1.6.0 for this cutover. If resolution selects any
  other 1.x release, stop and revalidate that release's Zig requirement before
  continuing.
- Zig must be pinned and locked at exactly 0.16.0.
- Retain the `mise.toml` note that Zig is required by Burrito at release-build time.
- Preserve `ECS_TASK_DEF_RELEASE_OS` and the existing two-target-per-host behavior.
- Preserve all `burrito_out/ecs_task_def_<os>_<arch>` artifact names, smoke tests, checksums, and publishing behavior.
- Delete `bin/xcrun`; do not add a replacement fallback.
- Active macOS CI and release jobs must use the standard ARM64 `macos-26` runner label.
- Do not rewrite historical files under `docs/superpowers/specs` or `docs/superpowers/plans`.
- Do not update unrelated Elixir dependencies, mise tools, or GitHub Actions versions.
- Treat a direct macOS 26 build without the repository shim as a blocking gate.

## File Map

- Modify `mix.exs`: raise the Burrito constraint and make the `BURRITO_TARGET` limitation comment version-neutral.
- Regenerate `mix.lock`: resolve Burrito 1.6.0 while preserving unrelated locked dependencies unless Burrito requires a transitive change.
- Modify `mise.toml`: raise the Zig pin and remove only the Darwin `PATH` prepend.
- Regenerate `mise.lock`: replace all locked Zig 0.15.2 platform records with Zig 0.16.0 records.
- Delete `bin/xcrun`: remove the obsolete macOS 14/15 SDK-selection shim.
- Modify `README.org`: remove the active description of the deleted workaround.
- Modify `.github/workflows/ci.yml`: move the macOS test matrix entry to `macos-26`.
- Modify `.github/workflows/release.yml`: move the binary build matrix to `macos-26` and remove the obsolete runner-pin explanation.
- Keep `test/release_tasks_test.exs` unchanged: it does not invoke the build task, and the cutover is covered by before/after source assertions, the existing full test suite, two real Burrito builds, binary validation, and the native smoke test.

---

### Task 1: Upgrade Burrito and Zig and Prove Direct macOS 26 Linking

**Files:**
- Modify: `mix.exs:22-30`
- Modify: `mix.lock:2`
- Modify: `mise.toml:1-8`
- Modify: `mise.lock:324-354`

**Interfaces:**
- Consumes: the published Burrito 1.6.0 Hex package, the mise Zig backend, the existing `ECS_TASK_DEF_RELEASE_OS=macos` selector, and `/usr/bin/xcrun`.
- Produces: Burrito 1.6.0 and Zig 0.16.0 locks plus fresh `burrito_out/ecs_task_def_macos_{aarch64,x86_64}` executables linked without `bin/xcrun` in `PATH`.

- [ ] **Step 1: Record the expected failing version assertions**

Require a clean starting tree:

```bash
test -z "$(git status --porcelain)"
```

Expected: pass. If it fails, stop and resolve the existing changes before
starting the cutover.

Run:

```bash
test "$(mise exec -- zig version)" = "0.16.0"
rg -n 'burrito.*"~> 1\.6"' mix.exs
```

Expected before the edit: both commands fail because the repository still pins Zig 0.15.2 and Burrito `~> 1.5`.

- [ ] **Step 2: Update the declared Burrito and Zig versions**

In `mix.exs`, change only the Burrito dependency:

```elixir
{:burrito, "~> 1.6"}
```

In `mise.toml`, retain the existing explanation and change only the version:

```toml
zig = "0.16.0" # required by burrito at release-build time
```

- [ ] **Step 3: Regenerate only the affected locks**

Run:

```bash
mise lock zig
mise install zig
mise exec -- mix deps.get
```

Expected:

- `mix.lock` resolves `burrito` to 1.6.0.
- Existing `jason`, `req`, and `typed_struct` locks remain unchanged unless the Burrito 1.6.0 package requires a transitive lock change.
- Every existing Zig platform entry in `mise.lock` uses a Zig 0.16.0 URL and checksum.
- No unrelated mise tool record changes.

Inspect the generated diff:

```bash
git diff -- mix.exs mix.lock mise.toml mise.lock
```

If either generated lock contains unrelated changes, restore that lock and
rerun its narrowest command:

```bash
git restore --source=HEAD -- mix.lock
mise exec -- mix deps.unlock burrito
mise exec -- mix deps.get
git restore --source=HEAD -- mise.lock
mise lock zig
```

The explicit Burrito unlock follows Mix's documented narrow-upgrade workflow:
it permits the direct dependency to move without unlocking its already-locked
children. Inspect the diff again and require `req` to remain at 0.6.3. If
unrelated changes persist, stop and report them; do not hand-edit either
lockfile.

- [ ] **Step 4: Verify the selected toolchain and post-install lock**

Run:

```bash
mise exec -- zig version
mise exec -- mix deps
git diff -- mise.lock
test "$(rg -c '0\.16\.0' mise.lock)" = "8"
! rg -q '0\.15\.2' mise.lock
```

Expected:

- Zig prints exactly `0.16.0`.
- `mix deps` lists exactly `burrito 1.6.0`; any other resolved Burrito version
  triggers the Global Constraints stop rule.
- `mise.lock` contains one Zig version line plus seven Zig 0.16.0 platform URL
  lines, contains no Zig 0.15.2 line, and has no unrelated post-install change.
- No dependency is divergent or unavailable.

Re-run the Step 1 assertions:

```bash
test "$(mise exec -- zig version)" = "0.16.0"
rg -n 'burrito.*"~> 1\.6"' mix.exs
```

Expected: both pass.

- [ ] **Step 5: Run the fast Elixir verification**

Run:

```bash
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test
mise exec -- mix ecs.regen_schema --check
```

Expected: formatting is unchanged, compilation emits no warnings, the complete ExUnit suite passes, and the generated schema/Pkl module has no drift.

- [ ] **Step 6: Prove the direct macOS 26 build before deleting the shim**

First prove the direct command resolves the system `xcrun`, not the repository shim:

```bash
test "$(mise exec -- sh -c 'command -v xcrun')" = "/usr/bin/xcrun"
```

Expected on the macOS 26 development host: pass.

Record the SDK target list as diagnostic context:

```bash
sdk_path="$(/usr/bin/xcrun --show-sdk-path)"
grep -m1 targets "$sdk_path/usr/lib/libSystem.tbd"
```

Expected on this host: the line contains `arm64e-macos` rather than
`arm64-macos`. This observation is diagnostic only; it does not predict Zig
0.16.0's result. The direct Burrito build below is the blocking experiment.

Build both macOS targets without invoking `mise run build`, because that task still prepends the repository shim at this checkpoint:

```bash
set -euo pipefail

artifact_quarantine="$(mktemp -d "${TMPDIR:-/tmp}/ecs-task-def-pre-zig-0.16.XXXXXX")"
if [ -d burrito_out ]; then
  mv burrito_out "$artifact_quarantine/"
fi
echo "preexisting Burrito artifacts, if any, are preserved at $artifact_quarantine"

ECS_TASK_DEF_RELEASE_OS=macos MIX_ENV=prod mise exec -- mix release ecs_task_def --overwrite
mise run release-check-binaries
file burrito_out/ecs_task_def_macos_aarch64 | rg -q 'Mach-O 64-bit executable arm64'
file burrito_out/ecs_task_def_macos_x86_64 | rg -q 'Mach-O 64-bit executable x86_64'
mise run release-smoke
```

Expected: the fail-fast block exits 0; Burrito completes both targets without
unresolved Darwin symbols and writes:

```text
burrito_out/ecs_task_def_macos_aarch64
burrito_out/ecs_task_def_macos_x86_64
```

The exact-two-binaries check and both machine-readable architecture assertions
pass, and the native aarch64 smoke test reports `release-smoke: passed`.
Because preexisting output was moved aside before the build, none of these
checks can pass against a stale Zig 0.15.2/shim-built binary.

Any non-zero command in the block is the stop condition. Diagnose the direct
Burrito 1.6.0/Zig 0.16.0 build rather than restoring or extending the shim, and
do not proceed to Task 2. If abandoning the attempt, restore the tracked
checkpoint with:

```bash
git restore --source=HEAD -- mix.exs mix.lock mise.toml mise.lock
```

- [ ] **Step 7: Commit the dependency and toolchain cutover**

Run:

```bash
git add mix.exs mix.lock mise.toml mise.lock
git commit -m "chore: upgrade Burrito and Zig"
```

---

### Task 2: Remove the SDK Shim and Stale Active Documentation

**Files:**
- Modify: `mise.toml:14-35`
- Modify: `mix.exs:51-59`
- Delete: `bin/xcrun`
- Modify: `README.org:162-180`

**Interfaces:**
- Consumes: the verified Burrito 1.6.0/Zig 0.16.0 direct macOS 26 build from Task 1.
- Produces: the existing `mise run build` interface with no repository-local `xcrun`, plus version-neutral active comments and documentation.

- [ ] **Step 1: Run the removal assertions and verify they fail**

Run:

```bash
test ! -e bin/xcrun
! rg -n -S 'export PATH="\$PWD/bin:\$PATH"|Burrito 1\.5|Zig 0\.15\.2|bin/xcrun|MacOSX1[45]|compatibility shim' mix.exs mise.toml README.org
```

Expected before the edit: failure because `bin/xcrun`, the Darwin `PATH` prepend, the version-specific selector comment, and the README workaround paragraph still exist.

- [ ] **Step 2: Remove the build-task PATH override**

Replace the Darwin arm of `tasks.build` in `mise.toml` with:

```sh
  Darwin)
    export ECS_TASK_DEF_RELEASE_OS=macos
    ;;
```

Do not change the Linux or unsupported-host branches, `MIX_ENV=prod`, the release name, or `--overwrite`.

- [ ] **Step 3: Delete the obsolete shim**

Run:

```bash
git rm bin/xcrun
```

The file is the only tracked content under `bin`; do not replace it or retain an empty placeholder file.

- [ ] **Step 4: Make the Burrito target-selector comment version-neutral**

Change the first line of the comment above `burrito_targets/0` in `mix.exs` to:

```elixir
# Burrito's own BURRITO_TARGET override only accepts a single target
```

Keep the rest of the explanation and `ECS_TASK_DEF_RELEASE_OS` implementation unchanged.

- [ ] **Step 5: Remove the obsolete README workaround paragraph**

Delete the four-line paragraph in `README.org` beginning with:

```text
On macOS 26, the task prepends ...
```

Do not replace it with another shim description. Keep the surrounding build-task and CI descriptions intact.

- [ ] **Step 6: Re-run the removal assertions**

Run:

```bash
test ! -e bin/xcrun
! rg -n -S 'export PATH="\$PWD/bin:\$PATH"|Burrito 1\.5|Zig 0\.15\.2|bin/xcrun|MacOSX1[45]|compatibility shim' mix.exs mise.toml README.org
```

Expected: pass with no matches.

Search the entire active tree while excluding generated dependencies, build output, Git metadata, and historical Superpowers documents:

```bash
! rg --hidden -n -S '0\.15\.2|Burrito 1\.5|macos-15|bin/xcrun|MacOSX1[45]|compatibility shim' \
  --glob '!docs/superpowers/**' \
  --glob '!deps/**' \
  --glob '!_build/**' \
  --glob '!burrito_out/**' \
  --glob '!.git/**' \
  .
```

Expected at this checkpoint: the assertion fails and prints exactly four lines,
all under `.github/workflows`: `ci.yml`'s `macos-15` matrix line plus
`release.yml`'s old Zig 0.15.2 explanation, compatibility-shim explanation,
and `macos-15` matrix line. Task 3 removes all four. Any match outside
`.github/workflows` is an incomplete Task 2 cleanup.

- [ ] **Step 7: Verify the shared build task without the shim**

Run:

```bash
set -euo pipefail

mise exec -- mix format --check-formatted
mise exec -- mix test

artifact_quarantine="$(mktemp -d "${TMPDIR:-/tmp}/ecs-task-def-pre-shim-removal.XXXXXX")"
if [ -d burrito_out ]; then
  mv burrito_out "$artifact_quarantine/"
fi
echo "preexisting Burrito artifacts, if any, are preserved at $artifact_quarantine"

mise run build
mise run release-check-binaries
file burrito_out/ecs_task_def_macos_aarch64 | rg -q 'Mach-O 64-bit executable arm64'
file burrito_out/ecs_task_def_macos_x86_64 | rg -q 'Mach-O 64-bit executable x86_64'
mise run release-smoke
```

Expected: the fail-fast block exits 0; formatting and tests pass; the normal
shared build task creates fresh macOS arm64 and x86_64 binaries using the
system SDK; both architecture assertions pass; and the native binary smoke
test passes.

- [ ] **Step 8: Commit the workaround removal**

Run:

```bash
git add mix.exs mise.toml README.org
git commit -m "chore: remove macOS SDK compatibility shim"
```

---

### Task 3: Move GitHub Actions to macOS 26 and Run the Full Gate

**Files:**
- Modify: `.github/workflows/ci.yml:12-17`
- Modify: `.github/workflows/release.yml:20-27`

**Interfaces:**
- Consumes: GitHub's generally available standard ARM64 `macos-26` runner and the shim-free `mise run build` task from Task 2.
- Produces: CI tests and release binary builds scheduled on macOS 26, with Linux jobs and all workflow steps otherwise unchanged.

- [ ] **Step 1: Record the expected failing workflow assertion**

Run:

```bash
! rg -n 'macos-15' .github/workflows/ci.yml .github/workflows/release.yml
```

Expected before the edit: failure with one `macos-15` matrix match in each workflow and the two-line obsolete explanation in `release.yml`.

- [ ] **Step 2: Update the CI test matrix**

In `.github/workflows/ci.yml`, use:

```yaml
matrix:
  os: [ubuntu-latest, macos-26]
```

Do not change any action version, mise version, cache behavior, or test step.

- [ ] **Step 3: Update the release binary matrix**

In `.github/workflows/release.yml`, delete the two comments explaining why macOS 15 avoided the old Zig/SDK incompatibility and use:

```yaml
matrix:
  os: [ubuntu-latest, macos-26]
```

Do not change the Linux runner, tag trigger, permissions, concurrency, build, smoke, checksum, or upload steps.

- [ ] **Step 4: Validate workflow syntax and labels**

Run:

```bash
ruby -e 'require "yaml"; ARGV.each { |path| YAML.safe_load(File.read(path), aliases: true, filename: path) }' \
  .github/workflows/ci.yml \
  .github/workflows/release.yml
```

Expected: exit 0 with no YAML parser error.

Run:

```bash
test "$(rg -l 'macos-26' .github/workflows/ci.yml .github/workflows/release.yml | wc -l | tr -d ' ')" = "2"
! rg -n 'macos-15' .github/workflows/ci.yml .github/workflows/release.yml
```

Expected: both workflow files contain `macos-26`, and neither contains `macos-15`.

- [ ] **Step 5: Run the complete active-reference sweep**

Run:

```bash
! rg --hidden -n -S '0\.15\.2|Burrito 1\.5|macos-15|bin/xcrun|MacOSX1[45]|compatibility shim' \
  --glob '!docs/superpowers/**' \
  --glob '!deps/**' \
  --glob '!_build/**' \
  --glob '!burrito_out/**' \
  --glob '!.git/**' \
  .
```

Expected: exit 0 with no matches. Historical plans/specs remain unchanged and are intentionally excluded.

- [ ] **Step 6: Run the complete local verification gate**

Run:

```bash
set -euo pipefail

mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test
mise exec -- mix ecs.regen_schema --check
mise exec -- mix deps.unlock --check-unused

artifact_quarantine="$(mktemp -d "${TMPDIR:-/tmp}/ecs-task-def-pre-final-build.XXXXXX")"
if [ -d burrito_out ]; then
  mv burrito_out "$artifact_quarantine/"
fi
echo "preexisting Burrito artifacts, if any, are preserved at $artifact_quarantine"

mise run build
mise run release-check-binaries
file burrito_out/ecs_task_def_macos_aarch64 | rg -q 'Mach-O 64-bit executable arm64'
file burrito_out/ecs_task_def_macos_x86_64 | rg -q 'Mach-O 64-bit executable x86_64'
mise run release-smoke
git diff --check
```

Expected:

- formatting passes;
- compilation emits no warnings;
- the complete ExUnit suite passes;
- the schema/Pkl drift check passes;
- no unused lock entries exist;
- Burrito builds exactly the macOS aarch64 and x86_64 executables directly against the macOS 26 SDK;
- both machine-readable architecture assertions pass;
- the native binary completes the CLI smoke test; and
- Git reports no whitespace errors.

- [ ] **Step 7: Review the final scope**

Run:

```bash
git status --short
git diff --stat main
git diff main -- mix.exs mix.lock mise.toml mise.lock README.org .github/workflows/ci.yml .github/workflows/release.yml bin/xcrun
```

Expected: only the focused cutover files and the approved design/plan documents differ from `main`; no unrelated dependency, mise tool, action-version, application-code, test, or historical-document change is present.

- [ ] **Step 8: Commit the workflow migration**

Run:

```bash
git add .github/workflows/ci.yml .github/workflows/release.yml
git commit -m "ci: move macOS jobs to macOS 26"
```

- [ ] **Step 9: Verify the committed branch is clean**

Run:

```bash
git status --short
git log --oneline main..HEAD
```

Expected: the worktree is clean, and the branch contains the design, design amendment, implementation plan, dependency/toolchain, shim-removal, and workflow commits.
