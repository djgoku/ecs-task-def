# Local Aqua Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in repository-local Aqua registry that installs supported `ecs-task-def` release binaries through mise without changing the project tool configuration.

**Architecture:** A root `registry.yaml` declares one templated `github_release` package for the existing raw macOS and Linux assets. An offline ExUnit contract test pins the registry fields to the producer-side release naming contract, while disposable live verification proves schema validity, version filtering, digest verification, sidecar correctness, and execution without touching `mise.toml` or `mise.lock`.

**Tech Stack:** Aqua registry YAML, mise 2026.7.0 Aqua backend, Elixir 1.20/ExUnit, Aqua 2.62.1 registry JSON schema, check-jsonschema 0.36.2, GitHub CLI, SHA-256

## Global Constraints

- Create `registry.yaml` at the repository root; do not add `aqua.yaml`.
- Do not modify `mise.toml` or the existing dirty `mise.lock`.
- The package coordinate is `aqua:djgoku/ecs-task-def`.
- Strip the release tag prefix `ecs-task-def@` so callers select `0.1.1`, `0.1.2`, or `latest`.
- Exclude only the broken `ecs-task-def@0.1.0` tag; `0.1.1` is the first supported release.
- Install raw assets named `ecs-task-def-{{.OS}}_{{.Arch}}` as the command `ecs-task-def`.
- Replace `darwin` with `macos`, `amd64` with `x86_64`, and `arm64` with `aarch64`.
- Support exactly `darwin/arm64`, `darwin/amd64`, `linux/arm64`, and `linux/amd64`.
- Declare the matching `{{.Asset}}.sha256` GitHub release asset with SHA-256.
- Treat GitHub's per-asset API digest as mise's normal verification source; the sidecar remains available to native Aqua and as a mise fallback.
- Local use must remain explicit through `MISE_AQUA_REGISTRIES=file://$PWD/registry.yaml`.
- Do not delete or modify any GitHub release or release asset.

---

### Task 1: Add the Registry and Offline Release-Contract Guard

**Files:**
- Create: `registry.yaml`
- Modify: `test/release_tasks_test.exs`

**Interfaces:**
- Consumes: the producer-side binary naming contract in `mise.toml` and `binary_asset_names/0` in `test/release_tasks_test.exs`
- Produces: the local registry coordinate `aqua:djgoku/ecs-task-def`, installed executable `ecs-task-def`, and the exact Aqua fields exercised by live verification

- [ ] **Step 1: Write the failing offline registry contract test**

Add this test immediately after the `setup` block in
`test/release_tasks_test.exs`:

```elixir
  test "local Aqua registry matches the release binary contract" do
    registry = File.read!(Path.join(@repo_root, "registry.yaml"))

    for fragment <- [
          "https://raw.githubusercontent.com/aquaproj/aqua/v2.62.1/json-schema/registry.json",
          "MISE_AQUA_REGISTRIES=file://$PWD/registry.yaml",
          "mise x aqua:djgoku/ecs-task-def@0.1.2 -- ecs-task-def --help",
          "type: github_release",
          "repo_owner: djgoku",
          "repo_name: ecs-task-def",
          ~s(version_prefix: "ecs-task-def@"),
          ~s(version_filter: 'Version != "ecs-task-def@0.1.0"'),
          ~s(asset: "ecs-task-def-{{.OS}}_{{.Arch}}"),
          "format: raw",
          "files:",
          "      - name: ecs-task-def",
          "darwin: macos",
          "amd64: x86_64",
          "arm64: aarch64",
          "darwin/arm64",
          "darwin/amd64",
          "linux/arm64",
          "linux/amd64",
          "checksum:",
          ~s(asset: "{{.Asset}}.sha256"),
          "algorithm: sha256"
        ] do
      assert registry =~ fragment, "registry.yaml is missing #{inspect(fragment)}"
    end

    mise_config = File.read!(Path.join(@repo_root, "mise.toml"))
    refute registry =~ "windows"
    refute mise_config =~ "aqua.registries"
    refute mise_config =~ "aqua:djgoku/ecs-task-def"
  end
```

This deliberately checks the small registry contract as text instead of adding
a YAML parser dependency to the application. Task 2 separately proves YAML
syntax and schema validity.

- [ ] **Step 2: Run the focused test and verify the missing registry fails**

Run:

```bash
mise exec -- mix test test/release_tasks_test.exs
```

Expected: FAIL in `local Aqua registry matches the release binary contract`
with `File.Error` because `registry.yaml` does not exist. The existing release
task tests should remain green.

- [ ] **Step 3: Add the minimal repository-local registry**

Create `registry.yaml` with exactly:

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/aquaproj/aqua/v2.62.1/json-schema/registry.json
# Local mise test from the repository root:
# MISE_AQUA_REGISTRIES=file://$PWD/registry.yaml \
#   mise x aqua:djgoku/ecs-task-def@0.1.2 -- ecs-task-def --help
packages:
  - type: github_release
    repo_owner: djgoku
    repo_name: ecs-task-def
    description: Generate validated Amazon ECS task-definition JSON from Pkl
    version_prefix: "ecs-task-def@"
    version_filter: 'Version != "ecs-task-def@0.1.0"'
    asset: "ecs-task-def-{{.OS}}_{{.Arch}}"
    format: raw
    files:
      - name: ecs-task-def
    replacements:
      darwin: macos
      amd64: x86_64
      arm64: aarch64
    supported_envs:
      - darwin/arm64
      - darwin/amd64
      - linux/arm64
      - linux/amd64
    checksum:
      type: github_release
      asset: "{{.Asset}}.sha256"
      algorithm: sha256
```

Do not edit `mise.toml` or `mise.lock`.

- [ ] **Step 4: Run the focused test and verify it passes**

Run:

```bash
mise exec -- mix test test/release_tasks_test.exs
```

Expected: all tests in `test/release_tasks_test.exs` pass, including the new
offline registry contract test.

- [ ] **Step 5: Check formatting and the intended diff**

Run:

```bash
mise exec -- mix format --check-formatted
git diff --check
git status --short
git diff -- registry.yaml test/release_tasks_test.exs
```

Expected:

- formatting and whitespace checks pass;
- `registry.yaml` is untracked and `test/release_tasks_test.exs` is modified;
- the pre-existing `mise.lock` modification is still present but unchanged;
- no other implementation files changed.

- [ ] **Step 6: Commit only the registry and its contract test**

Run:

```bash
git add registry.yaml test/release_tasks_test.exs
git commit -m "build: add local aqua registry"
```

Expected: the commit contains exactly `registry.yaml` and
`test/release_tasks_test.exs`; `mise.lock` remains unstaged.

---

### Task 2: Prove the Registry Through Isolated Aqua/mise Installation

**Files:**
- Verify: `registry.yaml`
- Verify: `mise.toml`
- Verify: `mise.lock`

**Interfaces:**
- Consumes: `registry.yaml` and public release `ecs-task-def@0.1.2`
- Produces: evidence that schema validation, mise parsing, version filtering, checksum verification, installation, and execution all satisfy the approved design without repository configuration mutation

- [ ] **Step 1: Prepare one disposable verification environment and snapshot protected files**

From the repository root, start a shell that will remain open through Step 6
and run:

```bash
export ECS_AQUA_REPO_ROOT="$PWD"
export ECS_AQUA_VERIFY_DIR
ECS_AQUA_VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ecs-task-def-aqua.XXXXXX")"
export ECS_AQUA_REGISTRY_URL="file://$ECS_AQUA_REPO_ROOT/registry.yaml"
export ECS_AQUA_MISE_TOML_BEFORE
export ECS_AQUA_MISE_LOCK_BEFORE
ECS_AQUA_MISE_TOML_BEFORE="$(shasum -a 256 "$ECS_AQUA_REPO_ROOT/mise.toml")"
ECS_AQUA_MISE_LOCK_BEFORE="$(shasum -a 256 "$ECS_AQUA_REPO_ROOT/mise.lock")"
mkdir -p "$ECS_AQUA_VERIFY_DIR/release-assets"
```

Expected: `ECS_AQUA_VERIFY_DIR` names a new disposable directory and both
protected-file hashes are recorded from their current contents, including the
user's existing `mise.lock` changes.

- [ ] **Step 2: Validate YAML against the pinned Aqua schema**

Run:

```bash
env \
  MISE_DATA_DIR="$ECS_AQUA_VERIFY_DIR/mise-data" \
  MISE_CACHE_DIR="$ECS_AQUA_VERIFY_DIR/mise-cache" \
  XDG_STATE_HOME="$ECS_AQUA_VERIFY_DIR/state" \
  MISE_GLOBAL_CONFIG_FILE=/dev/null \
  mise --no-config x pipx:check-jsonschema@0.36.2 -- \
  check-jsonschema \
  --schemafile https://raw.githubusercontent.com/aquaproj/aqua/v2.62.1/json-schema/registry.json \
  "$ECS_AQUA_REPO_ROOT/registry.yaml"
```

Expected: exit `0` with no schema validation errors. The exact one-off
`pipx:check-jsonschema@0.36.2` tool request is isolated under the disposable
mise data directory and does not enter the project lockfile.

- [ ] **Step 3: Load the local registry and verify its visible versions**

Run:

```bash
env \
  MISE_DATA_DIR="$ECS_AQUA_VERIFY_DIR/mise-data" \
  MISE_CACHE_DIR="$ECS_AQUA_VERIFY_DIR/mise-cache" \
  XDG_STATE_HOME="$ECS_AQUA_VERIFY_DIR/state" \
  MISE_GLOBAL_CONFIG_FILE=/dev/null \
  MISE_AQUA_REGISTRIES="$ECS_AQUA_REGISTRY_URL" \
  MISE_MINIMUM_RELEASE_AGE=0 \
  mise --no-config ls-remote aqua:djgoku/ecs-task-def \
  >"$ECS_AQUA_VERIFY_DIR/versions.txt"

rg -x "0.1.1" "$ECS_AQUA_VERIFY_DIR/versions.txt"
rg -x "0.1.2" "$ECS_AQUA_VERIFY_DIR/versions.txt"
if rg -x "0.1.0" "$ECS_AQUA_VERIFY_DIR/versions.txt"; then
  echo "broken 0.1.0 must not be visible" >&2
  exit 1
fi
```

Expected: mise parses `registry.yaml`; `versions.txt` contains stripped
versions `0.1.1` and `0.1.2`, and contains no `0.1.0`.

- [ ] **Step 4: Install and execute `0.1.2` with GitHub API digest verification**

Run:

```bash
set -o pipefail
env \
  MISE_DATA_DIR="$ECS_AQUA_VERIFY_DIR/mise-data" \
  MISE_CACHE_DIR="$ECS_AQUA_VERIFY_DIR/mise-cache" \
  XDG_STATE_HOME="$ECS_AQUA_VERIFY_DIR/state" \
  MISE_GLOBAL_CONFIG_FILE=/dev/null \
  MISE_AQUA_REGISTRIES="$ECS_AQUA_REGISTRY_URL" \
  MISE_MINIMUM_RELEASE_AGE=0 \
  mise -vv --no-config x aqua:djgoku/ecs-task-def@0.1.2 -- \
  ecs-task-def --help \
  2>&1 | tee "$ECS_AQUA_VERIFY_DIR/mise-install.log"

rg -F "using GitHub API digest for checksum verification" \
  "$ECS_AQUA_VERIFY_DIR/mise-install.log"
```

Expected: the exact release installs as a raw executable, `ecs-task-def
--help` exits `0`, and the verbose log proves mise used the GitHub API's
per-asset digest.

- [ ] **Step 5: Verify the separately published SHA-256 sidecar**

Run:

```bash
case "$(uname -s)" in
  Darwin) ecs_aqua_os=macos ;;
  Linux) ecs_aqua_os=linux ;;
  *)
    echo "unsupported host OS: $(uname -s)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  arm64|aarch64) ecs_aqua_arch=aarch64 ;;
  x86_64|amd64) ecs_aqua_arch=x86_64 ;;
  *)
    echo "unsupported host architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

ecs_aqua_asset="ecs-task-def-${ecs_aqua_os}_${ecs_aqua_arch}"
gh release download "ecs-task-def@0.1.2" \
  --repo djgoku/ecs-task-def \
  --pattern "$ecs_aqua_asset" \
  --pattern "$ecs_aqua_asset.sha256" \
  --dir "$ECS_AQUA_VERIFY_DIR/release-assets"

(
  cd "$ECS_AQUA_VERIFY_DIR/release-assets"
  shasum -a 256 -c "$ecs_aqua_asset.sha256"
)
```

Expected: both assets download and `shasum` reports
`<host asset name>: OK`.

- [ ] **Step 6: Run full repository verification and prove protected files are unchanged**

Run:

```bash
cd "$ECS_AQUA_REPO_ROOT"
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test
mise exec -- mix ecs.regen_schema --check
git diff --check

test "$ECS_AQUA_MISE_TOML_BEFORE" = "$(shasum -a 256 mise.toml)"
test "$ECS_AQUA_MISE_LOCK_BEFORE" = "$(shasum -a 256 mise.lock)"
git status --short
```

Expected:

- formatting, compilation, the complete ExUnit suite, schema regeneration
  drift check, and whitespace checks all pass;
- the before/after hashes for `mise.toml` and the already-dirty `mise.lock`
  match exactly;
- the implementation commit is present and only the user's pre-existing
  `mise.lock` change remains uncommitted.
