# Burrito Binary Checksums Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a conventional SHA-256 sidecar with every Burrito release
binary and document how users verify downloads.

**Architecture:** `release-publish-binaries` prepares both renamed host
binaries and their checksums in a private temporary directory before it calls
the GitHub-mutating `release-ensure` task. The release-task test harness
captures fake uploads synchronously, allowing ExUnit to verify the released
bytes, checksum contents, and prepare-before-mutate failure ordering.

**Tech Stack:** Bash 3.2-compatible mise tasks, `shasum`, GitHub CLI, Elixir
1.20/ExUnit, Org-mode documentation, GitHub Actions

## Global Constraints

- Keep `mix.exs` and `pkl/PklProject` at version `0.1.0`.
- Keep release shell logic in composable mise tasks; do not add inline shell to
  `.github/workflows/release.yml`.
- Generate exactly one `.sha256` sidecar for each of the four Burrito release
  binaries.
- Sidecars must contain a lowercase SHA-256 digest, two spaces, the released
  binary basename, and a trailing newline.
- Use `shasum -a 256`, which is available on both supported macOS and Ubuntu
  GitHub runners; do not add a checksum tool to `mise.toml`.
- Prepare both current-host binaries and both sidecars before
  `release-ensure` or any `gh release upload`.
- Preserve `release-check-binaries`, Pkl packaging/publishing behavior, exact
  source-artifact validation, and `--clobber` uploads.
- Use a task-private `mktemp -d` directory and remove it on every exit after
  successful creation.
- Treat checksums as download-integrity evidence, not signed authenticity; do
  not add artifact signing.
- Do not delete a GitHub release or move a tag without explicit approval
  immediately before the operation.

---

## File Structure

- Modify `mise.toml`: prepare, checksum, and upload binary release assets.
- Modify `test/release_tasks_test.exs`: capture fake uploads and prove checksum
  content and failure ordering.
- Modify `test/support/fake_gh.sh`: copy uploaded files into the fixture while
  still recording every argument vector.
- Modify `README.org`: explain how to download and verify a release binary.
- Do not modify `.github/workflows/release.yml`: its existing
  `mise run release-publish-binaries` call is the desired interface.

### Task 1: Generate and Verify Binary Checksum Assets

**Files:**

- Modify: `test/release_tasks_test.exs:8-113`
- Modify: `test/release_tasks_test.exs:172-334`
- Modify: `test/support/fake_gh.sh:4-36`
- Modify: `mise.toml:236-264`

**Interfaces:**

- Consumes: the exact executable
  `burrito_out/ecs_task_def_<host-os>_{aarch64,x86_64}` files accepted by
  `release-check-binaries`, `RELEASE_TAG`, `GH_TOKEN`, `shasum`, and the
  existing `release-ensure` task.
- Produces: four uploads per host in this exact order:
  `ecs-task-def-<host-os>_aarch64`,
  `ecs-task-def-<host-os>_aarch64.sha256`,
  `ecs-task-def-<host-os>_x86_64`, and
  `ecs-task-def-<host-os>_x86_64.sha256`.
- Test-only input: `FAKE_GH_UPLOAD_DIR`, an existing fixture directory where
  fake `gh release upload` copies its fourth argument.

- [ ] **Step 1: Extend the fake GitHub harness and write failing checksum tests**

In `test/support/fake_gh.sh`, require the capture directory and replace the
`upload` branch with a strict synchronous capture:

```bash
: "${FAKE_GH_UPLOAD_DIR:?FAKE_GH_UPLOAD_DIR is required}"

# Existing argument logging and create/view cases remain unchanged.

  upload)
    if [ "$#" -ne 5 ] || [ "${5:-}" != "--clobber" ]; then
      exit 64
    fi

    asset="${4:-}"
    if [ ! -f "$asset" ]; then
      exit 66
    fi

    cp "$asset" "$FAKE_GH_UPLOAD_DIR/$(basename "$asset")"
    exit 0
    ;;
```

In `test/release_tasks_test.exs`, create and expose a capture directory in
`setup`. Keep the existing fake `cp` and its stable-`/tmp` protection comment
through the intentionally failing test run in Step 2:

```elixir
upload_dir = Path.join(fixture, "uploads")

File.mkdir_p!(Path.join(fixture, "pkl"))
File.mkdir_p!(bin_dir)
File.mkdir_p!(state_dir)
File.mkdir_p!(upload_dir)

# Keep the existing fixture copies, fake-gh setup, and fake-cp setup.
File.write!(gh_log, "")

%{
  bin_dir: bin_dir,
  fixture: fixture,
  gh_log: gh_log,
  state_dir: state_dir,
  upload_dir: upload_dir
}
```

Add the capture directory to `run_task/3`:

```elixir
env = [
  {"FAKE_GH_LOG", context.gh_log},
  {"FAKE_GH_MODE", mode},
  {"FAKE_GH_UPLOAD_DIR", context.upload_dir},
  {"GH_TOKEN", "fake-token"},
  {"MISE_AUTO_INSTALL", "0"},
  {"MISE_DISABLE_TOOLS", "gh"},
  {"MISE_TRUSTED_CONFIG_PATHS", Path.join(context.fixture, "mise.toml")},
  {"PATH", context.bin_dir <> ":" <> System.fetch_env!("PATH")},
  {"RELEASE_TAG", @release_tag},
  {"XDG_STATE_HOME", context.state_dir}
]
```

Replace the existing binary happy-path test with:

```elixir
test "release-publish-binaries uploads exact binaries and valid SHA-256 sidecars",
     context do
  create_valid_binaries(context.fixture)

  {output, status} = run_task(context, "release-publish-binaries", "create-ok")

  assert status == 0, output
  assert uploaded_asset_names(context) == binary_asset_names()

  shasum = System.find_executable("shasum") || raise "shasum is required"

  for arch <- ["aarch64", "x86_64"] do
    name = "ecs-task-def-#{host_os()}_#{arch}"
    source = File.read!(binary_path(context.fixture, arch))
    captured_binary = Path.join(context.upload_dir, name)
    captured_checksum = Path.join(context.upload_dir, "#{name}.sha256")

    assert File.read!(captured_binary) == source

    digest =
      source
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert File.read!(captured_checksum) == "#{digest}  #{name}\n"

    {check_output, check_status} =
      System.cmd(shasum, ["-a", "256", "-c", "#{name}.sha256"],
        cd: context.upload_dir,
        stderr_to_stdout: true
      )

    assert check_status == 0, check_output
    assert check_output =~ "#{name}: OK"
  end
end
```

Add a preparation-failure test. The fixture is unique per test, so this fake
does not affect the happy path:

```elixir
test "release-publish-binaries stops before GitHub mutation when shasum fails",
     context do
  create_valid_binaries(context.fixture)

  fake_shasum = Path.join(context.bin_dir, "shasum")
  File.write!(fake_shasum, "#!/usr/bin/env bash\nexit 73\n")
  File.chmod!(fake_shasum, 0o755)

  {output, status} = run_task(context, "release-publish-binaries", "create-ok")

  assert status != 0, "checksum failure unexpectedly succeeded:\n#{output}"
  assert_no_github_mutation(context, :checksum_failure)
  assert File.ls!(context.upload_dir) == []
end
```

Add helpers that enforce exact upload order and basenames:

```elixir
defp binary_asset_names do
  for arch <- ["aarch64", "x86_64"],
      suffix <- ["", ".sha256"] do
    "ecs-task-def-#{host_os()}_#{arch}#{suffix}"
  end
end

defp uploaded_asset_names(context) do
  Enum.map(upload_lines(context), fn line ->
    ["release", "upload", @release_tag, path, "--clobber"] =
      String.split(line)

    Path.basename(path)
  end)
end
```

- [ ] **Step 2: Run the focused tests and verify the new behavior fails**

Run:

```bash
mise exec -- mix test test/release_tasks_test.exs
```

Expected: FAIL. The happy path cannot capture the old task's `/tmp` asset
because fake `cp` deliberately creates nothing, and the checksum-failure case
records a `release create` because the current task never invokes `shasum`.
The fake prevents the red test run from creating stable `/tmp` files. Existing
source-artifact rejection and Pkl cases must still avoid real GitHub mutation.

- [ ] **Step 3: Implement checksum preparation before GitHub mutation**

First, remove this exact block from `test/release_tasks_test.exs` so the passing
test run exercises real copies into the new private temporary directory:

```elixir
# Binary publishing intentionally uses stable /tmp asset names. Avoid
# touching a developer's existing files while still exercising the real
# task's renaming and gh-upload argument construction.
fake_cp = Path.join(bin_dir, "cp")
File.write!(fake_cp, "#!/usr/bin/env bash\nset -euo pipefail\n[ \"$#\" -eq 2 ]\n")
File.chmod!(fake_cp, 0o755)
```

Replace `release-publish-binaries` in `mise.toml` with:

```toml
[tasks.release-publish-binaries]
description = "Upload this host OS's two Burrito binaries and SHA-256 sidecars"
depends = ["release-validate-tag", "release-check-binaries"]
shell = "bash -c"
run = '''
set -euo pipefail

if ! command -v shasum >/dev/null 2>&1; then
  echo "::error::shasum is required to generate binary SHA-256 sidecars" >&2
  exit 1
fi

tag="${RELEASE_TAG:-}"
case "$(uname -s)" in
  Darwin) release_os=macos ;;
  Linux) release_os=linux ;;
  *)
    echo "::error::unsupported host OS: $(uname -s) (expected Darwin or Linux)" >&2
    exit 1
    ;;
esac

asset_dir="$(mktemp -d "${TMPDIR:-/tmp}/ecs-task-def-release.XXXXXX")"
trap 'rm -rf "$asset_dir"' EXIT

bins=(
  "burrito_out/ecs_task_def_${release_os}_aarch64"
  "burrito_out/ecs_task_def_${release_os}_x86_64"
)
assets=()
for bin in "${bins[@]}"; do
  name="$(basename "$bin" | sed 's/^ecs_task_def_/ecs-task-def-/')"
  cp "$bin" "$asset_dir/$name"
  (
    cd "$asset_dir"
    shasum -a 256 "$name" > "$name.sha256"
  )
  assets+=("$asset_dir/$name" "$asset_dir/$name.sha256")
done

mise run release-ensure

for asset in "${assets[@]}"; do
  gh release upload "$tag" "$asset" --clobber
done
'''
```

Do not modify `release-check-binaries`, `release-ensure`,
`release-publish-pkl`, or `.github/workflows/release.yml`.

- [ ] **Step 4: Run the focused tests and verify they pass**

Run:

```bash
mise exec -- mix test test/release_tasks_test.exs
```

Expected: `20 tests, 0 failures`. The happy path captures two binaries and two
sidecars, both `shasum -c` checks pass, and the injected checksum failure
records no `release create` or `release upload`.

- [ ] **Step 5: Format and validate the changed task boundary**

Run:

```bash
mise exec -- mix format
mise exec -- mix format --check-formatted
mise task info release-publish-binaries
git diff --check
```

Expected: formatting is unchanged after the first command,
`release-publish-binaries` parses with both existing safe dependencies, and
`git diff --check` prints nothing.

- [ ] **Step 6: Commit the checksum implementation with GPG signing**

```bash
git add mise.toml test/release_tasks_test.exs test/support/fake_gh.sh
git commit -S -m "feat: publish Burrito binary checksums"
```

Expected: one signed commit containing only the mise task and its automated
test harness.

### Task 2: Document Download Verification and Run the Full Suite

**Files:**

- Modify: `README.org:18-79`

**Interfaces:**

- Consumes: release assets named
  `ecs-task-def-<host-os>_<arch>` and
  `ecs-task-def-<host-os>_<arch>.sha256`.
- Produces: a copyable `shasum -a 256 -c` verification command and an explicit
  integrity-versus-authenticity boundary for users.

- [ ] **Step 1: Confirm the README does not yet document checksum verification**

Run:

```bash
rg -n 'shasum -a 256 -c|download corruption' README.org
```

Expected: no matches.

- [ ] **Step 2: Replace the stale installation release text**

Replace the paragraph beginning `~ecs-task-def~ ships as a single
self-contained binary` through `Contributing below` with:

```org
~ecs-task-def~ ships as a single self-contained binary (via
[[https://github.com/burrito-elixir/burrito][Burrito]]) for macOS and Linux.
Download the binary and matching ~.sha256~ file for your platform from this
repo's
[[https://github.com/djgoku/aws-ecs-task-definition-generator/releases][GitHub Releases]]
page, verify the download, and put the binary on your ~PATH~:

#+begin_src console
$ shasum -a 256 -c ecs-task-def-macos_aarch64.sha256
ecs-task-def-macos_aarch64: OK
#+end_src

Substitute the filename for your operating system and architecture. The
checksum detects download corruption; because it is published beside the
binary, it is not a signed proof of authenticity. To run from source instead,
see Contributing below.
```

In the `ecs-task-def init` usage section, replace the paragraph beginning
`*Until the first tagged release exists` and its following `--vendor` console
block with:

```org
~--vendor~ additionally writes a local ~EcsSchema.pkl~ next to ~mytask.pkl~,
which ~amends~ that file instead of a package URL. This mode is fully offline
and remains useful for air-gapped hosts or hermetic CI:

#+begin_src console
$ ecs-task-def init --vendor
created ./mytask.pkl
created ./EcsSchema.pkl
#+end_src
```

Replace the paragraph beginning `Plain ~init~` through `(offline after that)`
with:

```org
Plain ~init~ (no ~--vendor~) instead makes ~mytask.pkl~ ~amends~ the
versioned package URL
~package://pkg.pkl-lang.org/github.com/djgoku/aws-ecs-task-definition-generator/ecs-task-def@X.Y.Z#/EcsSchema.pkl~,
where ~X.Y.Z~ is the running binary's version. The first ~generate~ fetches
the matching schema package over HTTPS and pkl caches it locally for later
offline use:
```

Keep the existing plain-`init` console example and the final sentence that
`init` never overwrites. Remove the now-redundant paragraph saying `--vendor`
remains useful after the first release.

- [ ] **Step 3: Verify the documentation and unchanged versions**

Run:

```bash
rg -n 'shasum -a 256 -c|download corruption|not a signed proof|air-gapped hosts|first ~generate~ fetches' README.org
if rg -n 'No release has been published yet|Until the first tagged release exists|since no release exists yet' README.org; then
  exit 1
fi
rg -n 'version: "0.1.0"' mix.exs
rg -n 'version = "0.1.0"' pkl/PklProject
git diff --check
```

Expected: all five current-release README phrases are present, no stale
pre-release phrase is found, both project files still report `0.1.0`, and
`git diff --check` prints nothing.

- [ ] **Step 4: Run compilation and the complete test suite**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test
```

Expected: compilation exits zero and the complete suite passes with the new
release-task test included.

- [ ] **Step 5: Confirm the workflow remains a thin mise caller**

Run:

```bash
rg -n 'mise run release-publish-binaries' .github/workflows/release.yml
rg -n 'shasum|sha256' .github/workflows/release.yml
git status --short
```

Expected: the first command finds the existing publishing step, the second
finds no inline checksum logic, and status shows only `README.org`.

- [ ] **Step 6: Commit the user documentation with GPG signing**

```bash
git add README.org
git commit -S -m "docs: explain binary checksum verification"
```

Expected: one signed documentation commit with no version changes.

### Task 3: Replace Release 0.1.0 After Merge

**Files:**

- Modify: none

**Interfaces:**

- Consumes: the merged checksum implementation at `origin/main`, explicit
  approval to delete the current release and move its tag, GitHub CLI
  authentication, and Git signing configuration.
- Produces: a fresh `ecs-task-def@0.1.0` GitHub release containing eight
  Burrito assets and the existing four Pkl assets.

- [ ] **Step 1: Stop until the implementation is merged and deletion is approved**

Do not run any command in this task while the implementation exists only on
`codex/binary-checksums`. Immediately before deletion, ask the user to approve
deleting the existing GitHub release, deleting the remote/local tag, and
recreating the signed `ecs-task-def@0.1.0` tag at updated `main`.

Expected: explicit approval in the active conversation.

- [ ] **Step 2: Verify the merged commit and unchanged versions**

Run:

```bash
git switch main
git pull --ff-only
git status --short --branch
git log -1 --oneline --decorate
rg -n 'version: "0.1.0"' mix.exs
rg -n 'version = "0.1.0"' pkl/PklProject
```

Expected: clean `main` aligned with `origin/main`, the checksum implementation
is present, and both versions remain `0.1.0`.

- [ ] **Step 3: Delete the existing release and old tag**

Run only after Step 1 approval:

```bash
gh release delete 'ecs-task-def@0.1.0' \
  --repo djgoku/aws-ecs-task-definition-generator \
  --yes
git push origin ':refs/tags/ecs-task-def@0.1.0'
git tag -d 'ecs-task-def@0.1.0'
```

Expected: the existing release is deleted, the remote tag deletion succeeds,
and the local tag is removed. Do not use `--cleanup-tag`; tag deletion remains
an explicit separate operation.

- [ ] **Step 4: Recreate and push the signed 0.1.0 tag**

Run:

```bash
git tag -s 'ecs-task-def@0.1.0' -m 'ecs-task-def 0.1.0'
git push origin 'ecs-task-def@0.1.0'
```

Expected: the tag points at updated `main`, the push succeeds, and the Release
workflow starts from the tag event.

- [ ] **Step 5: Watch the workflow and verify the complete asset set**

Poll for the Release run whose head SHA matches the newly tagged commit. This
avoids watching an older run while GitHub is still registering the tag event:

```bash
head_sha="$(git rev-parse HEAD)"
run_id=""
for _ in {1..30}; do
  run_id="$(
    gh run list \
      --repo djgoku/aws-ecs-task-definition-generator \
      --workflow Release \
      --event push \
      --limit 20 \
      --json databaseId,headSha \
      --jq ".[] | select(.headSha == \"$head_sha\") | .databaseId" |
      head -n 1
  )"
  [ -n "$run_id" ] && break
  sleep 2
done
test -n "$run_id"
```

Then watch that commit-matched run and inspect its release:

```bash
gh run watch "$run_id" \
  --repo djgoku/aws-ecs-task-definition-generator \
  --exit-status
gh release view 'ecs-task-def@0.1.0' \
  --repo djgoku/aws-ecs-task-definition-generator \
  --json assets \
  --jq '.assets[].name'
```

Expected: the workflow succeeds and the release lists exactly these twelve
assets:

```text
ecs-task-def-linux_aarch64
ecs-task-def-linux_aarch64.sha256
ecs-task-def-linux_x86_64
ecs-task-def-linux_x86_64.sha256
ecs-task-def-macos_aarch64
ecs-task-def-macos_aarch64.sha256
ecs-task-def-macos_x86_64
ecs-task-def-macos_x86_64.sha256
ecs-task-def@0.1.0
ecs-task-def@0.1.0.sha256
ecs-task-def@0.1.0.zip
ecs-task-def@0.1.0.zip.sha256
```

- [ ] **Step 6: Verify a published binary against its published sidecar**

In a disposable temporary directory, download one binary and its checksum:

```bash
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ecs-task-def-release-check.XXXXXX")"
gh release download 'ecs-task-def@0.1.0' \
  --repo djgoku/aws-ecs-task-definition-generator \
  --pattern 'ecs-task-def-macos_aarch64*' \
  --dir "$tmp_dir"
(
  cd "$tmp_dir"
  shasum -a 256 -c ecs-task-def-macos_aarch64.sha256
)
rm -rf "$tmp_dir"
```

Expected: `ecs-task-def-macos_aarch64: OK`. This temporary-directory removal is
part of the explicitly approved release verification, and must target only the
fresh path returned by `mktemp -d`.
