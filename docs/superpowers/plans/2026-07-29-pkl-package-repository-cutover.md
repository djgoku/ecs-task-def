# Pkl Package Repository Cutover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare locally verified `ecs-task-def` 0.1.1 source and Pkl package artifacts that consistently use the canonical `djgoku/ecs-task-def` repository.

**Architecture:** Treat `pkl/PklProject` as the published package-coordinate source and regression-test its relationship with the package URI compiled into scaffolded configurations. Keep the application and Pkl versions in lockstep, update active user-facing references, then exercise the repository's real Pkl release-packaging gate without publishing anything.

**Tech Stack:** Elixir 1.20.1 / Erlang/OTP 29.0.2, ExUnit, Pkl 0.31.1, mise 2026.7.0, Git worktrees, Org documentation

## Global Constraints

- Work only in `/private/tmp/ecs-task-def-fix-pkl-repository` on branch `codex/fix-pkl-package-repository`, based on `main`.
- Use `djgoku/ecs-task-def` as the canonical GitHub repository.
- Set both `mix.exs` and `pkl/PklProject` to exactly version 0.1.1.
- Use exactly `package://pkg.pkl-lang.org/github.com/djgoku/ecs-task-def/ecs-task-def` as the Pkl package base URI.
- Use exactly `https://github.com/djgoku/ecs-task-def/releases/download/ecs-task-def@0.1.1/ecs-task-def@0.1.1.zip` as the generated 0.1.1 ZIP URL.
- Keep historical files under `docs/superpowers/` unchanged except for this approved specification and implementation plan.
- Do not change dependencies, mise tools, release tasks, GitHub workflows, or generated schema content.
- Do not create or move tags, create or edit GitHub releases, upload assets, or alter the existing 0.1.0 release.
- Keep `pkl/.out/` absent or empty before validating the 0.1.1 package; do not regenerate 0.1.0 there.
- Treat a network-only `--skip-publish-check` fallback as an explicitly reported, unvalidated CI-path gap.

## File Map

- Modify `mix.exs`: bump the application version to 0.1.1.
- Modify `pkl/PklProject`: bump the package version and correct `baseUri` and `packageZipUrl`.
- Modify `lib/ecs_task_def/scaffold.ex`: compile the canonical package base into generated starter files.
- Modify `test/ecs_task_def/scaffold_test.exs`: update the stale assertion and cover canonical metadata, coordinate coupling, and version lockstep.
- Modify `test/release_tasks_test.exs`: derive its versioned fixture values rather than pinning 0.1.0.
- Modify `README.org`: correct the active release link and two active Pkl package examples.
- Create ignored files only under `pkl/.out/ecs-task-def@0.1.1/` by running the existing package task.

---

### Task 1: Cut Over the Version and Package Coordinate with Regression Coverage

**Files:**
- Modify: `mix.exs:7`
- Modify: `pkl/PklProject:5-7`
- Modify: `lib/ecs_task_def/scaffold.ex:10`
- Modify: `test/ecs_task_def/scaffold_test.exs:4-23`
- Modify: `test/release_tasks_test.exs:4-6`

**Interfaces:**
- Consumes: `EcsTaskDef.Scaffold.init/2`, `Application.spec(:ecs_task_def, :vsn)`, and the `pkl:Project` package fields.
- Produces: application/package version 0.1.1, canonical Pkl metadata declarations, and scaffolded `amends` URIs of the form `#{baseUri}@0.1.1#/EcsSchema.pkl`.

- [ ] **Step 1: Add the failing coordinate-coupling regression test**

In `test/ecs_task_def/scaffold_test.exs`, add these attributes below the
`alias`:

```elixir
  @repo_root Path.expand("../..", __DIR__)
  @canonical_package_base "package://pkg.pkl-lang.org/github.com/djgoku/ecs-task-def/ecs-task-def"
  @canonical_release_base "https://github.com/djgoku/ecs-task-def/releases/download/"
```

Add this test after the existing default-init test. Do not update the existing
stale assertion yet:

```elixir
  test "Pkl metadata and scaffold use the same canonical coordinate", %{dir: dir} do
    project = File.read!(Path.join(@repo_root, "pkl/PklProject"))

    assert project =~ ~s[baseUri = "#{@canonical_package_base}"]
    assert project =~ ~s[packageZipUrl = "#{@canonical_release_base}]

    assert [_, package_base] =
             Regex.run(~r/^\s*baseUri = "([^"]+)"$/m, project)

    assert [_, pkl_version] =
             Regex.run(~r/^\s*version = "([^"]+)"/m, project)

    app_version = Application.spec(:ecs_task_def, :vsn) |> to_string()
    assert pkl_version == app_version

    assert {:ok, [task_path]} = Scaffold.init(dir, false)

    assert File.read!(task_path) =~
             ~s[amends "#{package_base}@#{app_version}#/EcsSchema.pkl"]
  end
```

- [ ] **Step 2: Run the new regression test and prove it fails for the stale coordinate**

Run:

```bash
env MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" \
  mise exec -- mix test test/ecs_task_def/scaffold_test.exs
```

Expected: FAIL at the canonical `baseUri` assertion because `pkl/PklProject`
still names `djgoku/aws-ecs-task-definition-generator`. The existing
default-init assertion continues to pass at this checkpoint; the new coupling
test is the only expected failure.

- [ ] **Step 3: Apply the minimal version and coordinate cutover**

In `mix.exs`, set:

```elixir
      version: "0.1.1",
```

Replace the package block in `pkl/PklProject` with:

```pkl
package {
  name = "ecs-task-def"
  baseUri = "package://pkg.pkl-lang.org/github.com/djgoku/ecs-task-def/ecs-task-def"
  version = "0.1.1" // keep in lockstep with mix.exs version
  packageZipUrl = "https://github.com/djgoku/ecs-task-def/releases/download/ecs-task-def@\(version)/ecs-task-def@\(version).zip"
  exclude { "PklProject" }
}
```

In `lib/ecs_task_def/scaffold.ex`, set:

```elixir
  @package_base "package://pkg.pkl-lang.org/github.com/djgoku/ecs-task-def/ecs-task-def"
```

Update the existing assertion in
`test/ecs_task_def/scaffold_test.exs` to:

```elixir
    assert contents =~
             ~s[amends "package://pkg.pkl-lang.org/github.com/djgoku/ecs-task-def/ecs-task-def@#{version}#/EcsSchema.pkl"]
```

Replace the two pinned attributes in `test/release_tasks_test.exs` with:

```elixir
  @version Mix.Project.config()[:version]
  @release_tag "ecs-task-def@#{@version}"
```

- [ ] **Step 4: Format and run the focused tests**

Run:

```bash
env MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" mise exec -- mix format
env MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" \
  mise exec -- mix test test/ecs_task_def/scaffold_test.exs
env MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" \
  mise exec -- mix test test/release_tasks_test.exs
```

Expected: formatting exits 0, all scaffold tests pass, and every release-task
test reaches its intended success or negative-path assertion with no
0.1.0/0.1.1 validation mismatch.

- [ ] **Step 5: Run the complete source verification**

Run:

```bash
env MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" \
  mise exec -- mix format --check-formatted
env MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" \
  mise exec -- mix compile --warnings-as-errors
env MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" mise exec -- mix test
env MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" \
  mise exec -- mix ecs.regen_schema --check
```

Expected: formatting is unchanged; compilation exits 0; all ExUnit tests pass;
and the generated schema/Pkl module has no drift. The pre-existing Mix
`xref: [exclude: ...]` deprecation warning may print, but this task must add no
new warnings.

- [ ] **Step 6: Inspect the Task 1 diff**

Run:

```bash
git diff --check
git diff --stat
git diff -- \
  mix.exs \
  pkl/PklProject \
  lib/ecs_task_def/scaffold.ex \
  test/ecs_task_def/scaffold_test.exs \
  test/release_tasks_test.exs
```

Expected: only the five Task 1 files change; the version is 0.1.1 in both
sources; every active package coordinate in these files uses
`djgoku/ecs-task-def`; and release tests derive their version.

- [ ] **Step 7: Commit the source cutover**

Run:

```bash
git add \
  mix.exs \
  pkl/PklProject \
  lib/ecs_task_def/scaffold.ex \
  test/ecs_task_def/scaffold_test.exs \
  test/release_tasks_test.exs
git commit -m "fix: use canonical Pkl package repository"
```

---

### Task 2: Update Active Documentation and Prove the 0.1.1 Package

**Files:**
- Modify: `README.org:24,71,187`
- Generate, ignored: `pkl/.out/ecs-task-def@0.1.1/ecs-task-def@0.1.1`
- Generate, ignored: `pkl/.out/ecs-task-def@0.1.1/ecs-task-def@0.1.1.sha256`
- Generate, ignored: `pkl/.out/ecs-task-def@0.1.1/ecs-task-def@0.1.1.zip`
- Generate, ignored: `pkl/.out/ecs-task-def@0.1.1/ecs-task-def@0.1.1.zip.sha256`

**Interfaces:**
- Consumes: Task 1's version 0.1.1, canonical Pkl declarations, and the existing `release-package-pkl`/`release-check-pkl` mise tasks.
- Produces: active documentation for `djgoku/ecs-task-def` plus a locally verified four-asset 0.1.1 package set ready for later publication.

- [ ] **Step 1: Record the three stale active README references**

Run:

```bash
rg -n 'djgoku/aws-ecs-task-definition-generator' README.org
```

Expected: exactly three matches, at the GitHub Releases link and the two active
Pkl package examples.

- [ ] **Step 2: Update all active README references**

Use these canonical replacements:

```org
[[https://github.com/djgoku/ecs-task-def/releases][GitHub Releases]]
```

```org
~package://pkg.pkl-lang.org/github.com/djgoku/ecs-task-def/ecs-task-def@X.Y.Z#/EcsSchema.pkl~,
```

```org
~package://pkg.pkl-lang.org/github.com/djgoku/ecs-task-def/ecs-task-def@X.Y.Z~
```

Do not modify any historical file under `docs/superpowers/`.

- [ ] **Step 3: Prove the active tree contains no stale repository reference**

Run:

```bash
! rg -n -S 'djgoku/aws-ecs-task-definition-generator' \
  --glob '!docs/superpowers/**' \
  --glob '!deps/**' \
  --glob '!_build/**' \
  --glob '!pkl/.out/**' \
  --glob '!.git/**' \
  .
```

Expected: exit 0 with no matches.

Also verify exact active versions and coordinates:

```bash
rg -n 'version: "0\.1\.1"' mix.exs
rg -n 'version = "0\.1\.1"' pkl/PklProject
rg -n 'package://pkg\.pkl-lang\.org/github\.com/djgoku/ecs-task-def/ecs-task-def' \
  pkl/PklProject lib/ecs_task_def/scaffold.ex README.org
```

Expected: both version assertions match and all active package references use
the canonical repository.

- [ ] **Step 4: Quarantine any pre-existing generated package output**

Run:

```bash
set -euo pipefail

artifact_quarantine="$(mktemp -d "${TMPDIR:-/tmp}/ecs-task-def-pre-pkl-0.1.1.XXXXXX")"
if [ -d pkl/.out ]; then
  mv pkl/.out "$artifact_quarantine/"
fi
echo "pre-existing Pkl package output, if any, is preserved at $artifact_quarantine"
test ! -e pkl/.out
```

Expected: `pkl/.out/` is absent before packaging, and any prior ignored output
is recoverable at the printed quarantine path.

- [ ] **Step 5: Confirm the optional fallback exists**

Run:

```bash
env MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" \
  mise exec -- pkl project package --help |
  rg -- '--skip-publish-check'
```

Expected: the help output contains `--skip-publish-check`. This only confirms
the fallback syntax; it does not authorize skipping the primary CI-equivalent
gate.

- [ ] **Step 6: Run the CI-equivalent Pkl packaging task**

Run:

```bash
env MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" \
  mise run release-package-pkl
```

Expected: exit 0. `pkl project package` completes its default publish check for
the unpublished 0.1.1 coordinate, then `release-check-pkl` prints:

```text
found exact readable Pkl package artifacts for version 0.1.1
```

Any non-zero result is a stop condition. Diagnose it before continuing. Only
when the exact error proves the environment cannot perform the network publish
check may the executor run:

```bash
(
  cd pkl
  env MISE_TRUSTED_CONFIG_PATHS="$PWD/../mise.toml" \
    mise exec -- pkl project package --skip-publish-check
)
env MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" \
  mise run release-check-pkl
```

If this fallback is used, record the primary command and exact network error as
an unvalidated CI-path gap in the final report.

- [ ] **Step 7: Verify exact artifacts, metadata, and the embedded ZIP checksum**

Run:

```bash
env MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" mise exec -- mix run -e '
metadata_path = "pkl/.out/ecs-task-def@0.1.1/ecs-task-def@0.1.1"
zip_path = metadata_path <> ".zip"
metadata = metadata_path |> File.read!() |> Jason.decode!()

expected_uri =
  "package://pkg.pkl-lang.org/github.com/djgoku/ecs-task-def/ecs-task-def@0.1.1"

expected_zip =
  "https://github.com/djgoku/ecs-task-def/releases/download/" <>
    "ecs-task-def@0.1.1/ecs-task-def@0.1.1.zip"

zip_sha =
  zip_path
  |> File.read!()
  |> then(&:crypto.hash(:sha256, &1))
  |> Base.encode16(case: :lower)

unless metadata["packageUri"] == expected_uri, do: raise("wrong packageUri")
unless metadata["version"] == "0.1.1", do: raise("wrong package version")
unless metadata["packageZipUrl"] == expected_zip, do: raise("wrong packageZipUrl")

unless get_in(metadata, ["packageZipChecksums", "sha256"]) == zip_sha,
  do: raise("metadata ZIP checksum mismatch")

IO.puts("validated canonical 0.1.1 Pkl metadata and ZIP checksum")
'
```

Expected:

```text
validated canonical 0.1.1 Pkl metadata and ZIP checksum
```

- [ ] **Step 8: Verify both checksum sidecars and the archive root**

Run:

```bash
set -euo pipefail

asset_dir="pkl/.out/ecs-task-def@0.1.1"
metadata="$asset_dir/ecs-task-def@0.1.1"
zip="$asset_dir/ecs-task-def@0.1.1.zip"

test "$(shasum -a 256 "$metadata" | awk '{print $1}')" = \
  "$(tr -d '\n' < "$metadata.sha256")"
test "$(shasum -a 256 "$zip" | awk '{print $1}')" = \
  "$(tr -d '\n' < "$zip.sha256")"
test "$(unzip -Z1 "$zip")" = "EcsSchema.pkl"
```

Expected: exit 0; both raw-digest sidecars match their corresponding files,
and `EcsSchema.pkl` is the ZIP's only root entry.

- [ ] **Step 9: Compare the new ZIP with the recorded 0.1.0 checksum**

Run:

```bash
set -euo pipefail

zip="pkl/.out/ecs-task-def@0.1.1/ecs-task-def@0.1.1.zip"
new_zip_sha="$(shasum -a 256 "$zip" | awk '{print $1}')"
old_zip_sha="9ecd70ea98753c5c47ebf25e8b4990b0daec2c97b480f846ddc05932c76726f8"

echo "0.1.0 ZIP SHA-256: $old_zip_sha"
echo "0.1.1 ZIP SHA-256: $new_zip_sha"
test "$new_zip_sha" = "$old_zip_sha"
```

Expected: both checksums are identical because `PklProject` is excluded and
`EcsSchema.pkl` is unchanged. If they differ, stop before committing and
inspect the ZIP metadata and archived schema hash; explain whether Pkl
packaging is non-deterministic or an unintended payload change occurred.

- [ ] **Step 10: Run the final source and package gates**

Run:

```bash
env MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" \
  mise exec -- mix format --check-formatted
env MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" mise exec -- mix test
env MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" \
  mise exec -- mix ecs.regen_schema --check
env MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" \
  mise run release-check-pkl
git diff --check
git status --short
```

Expected: formatting, all ExUnit tests, schema regeneration check, and exact
four-artifact gate pass. Git shows only `README.org` as an uncommitted tracked
change; generated package artifacts remain ignored.

- [ ] **Step 11: Commit the active documentation update**

Run:

```bash
git add README.org
git commit -m "docs: use canonical ecs-task-def repository"
```

- [ ] **Step 12: Record the post-publication gate without executing it**

After 0.1.1 is published in a separate authorized workflow, run:

```bash
pkl download-package \
  --cache-dir "$(mktemp -d)" \
  "package://pkg.pkl-lang.org/github.com/djgoku/ecs-task-def/ecs-task-def@0.1.1"
```

Do not execute this step during source implementation because the 0.1.1
metadata and ZIP do not exist at their HTTPS locations until publication.
Do not modify or delete 0.1.0 in this branch.
