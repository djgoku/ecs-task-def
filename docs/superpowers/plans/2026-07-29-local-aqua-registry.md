# Local Aqua Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in repository-local Aqua registry that installs supported `ecs-task-def` release binaries through mise without changing the project tool configuration.

**Architecture:** A root `registry.yaml` declares one templated `github_release` package for the existing raw macOS and Linux assets. Offline ExUnit tests pin the registry fields and rendered asset names to the producer-side release naming contract. Disposable live verification proves schema validity, version filtering, GitHub API digest verification, and execution; the published checksum sidecar is verified independently because mise's normal API-digest path does not exercise the registry's fallback checksum declaration.

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
- Consumes: the producer-side binary naming contract in `mise.toml` and `binary_asset_names/1` in `test/release_tasks_test.exs`
- Produces: the local registry coordinate `aqua:djgoku/ecs-task-def`, installed executable `ecs-task-def`, and the exact Aqua fields exercised by live verification

- [ ] **Step 1: Snapshot protected files before the first mise command**

From the repository root, start a shell that will remain open through Task 2
and run:

```bash
export ECS_AQUA_REPO_ROOT="$PWD"
export ECS_AQUA_VERIFY_DIR
ECS_AQUA_VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ecs-task-def-aqua.XXXXXX")"
export ECS_AQUA_REGISTRY_URL="file://$ECS_AQUA_REPO_ROOT/registry.yaml"

mkdir -p "$ECS_AQUA_VERIFY_DIR/release-assets"
mkdir -p "$ECS_AQUA_VERIFY_DIR/config"
mkdir -p "$ECS_AQUA_VERIFY_DIR/xdg-config"
mkdir -p "$ECS_AQUA_VERIFY_DIR/state"
: >"$ECS_AQUA_VERIFY_DIR/global.toml"

cp -p "$ECS_AQUA_REPO_ROOT/mise.toml" \
  "$ECS_AQUA_VERIFY_DIR/mise.toml.before"
cp -p "$ECS_AQUA_REPO_ROOT/mise.lock" \
  "$ECS_AQUA_VERIFY_DIR/mise.lock.before"
```

Expected: the disposable directory contains byte-for-byte baseline copies of
both protected files before any implementation command can invoke mise. The
`mise.lock` copy includes the user's pre-existing changes.

- [ ] **Step 2: Write failing offline registry contract tests**

Near the existing release-tag module attributes in
`test/release_tasks_test.exs`, add:

```elixir
  @aqua_replacements %{
    "darwin" => "macos",
    "amd64" => "x86_64",
    "arm64" => "aarch64"
  }
```

Add these tests immediately after the `setup` block:

```elixir
  test "local Aqua registry declares the supported package contract" do
    registry = File.read!(Path.join(@repo_root, "registry.yaml"))

    for fragment <- [
          "https://raw.githubusercontent.com/aquaproj/aqua/v2.62.1/json-schema/registry.json",
          "MISE_AQUA_REGISTRIES=file://$PWD/registry.yaml",
          "mise x aqua:djgoku/ecs-task-def@",
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

  test "local Aqua asset template renders producer-side release names" do
    registry = File.read!(Path.join(@repo_root, "registry.yaml"))

    [_, template] =
      Regex.run(
        ~r/^\s*asset: "(ecs-task-def-\{\{\.OS\}\}_\{\{\.Arch\}\})"$/m,
        registry
      )

    for {aqua_os, aqua_arch} <- [
          {"darwin", "arm64"},
          {"darwin", "amd64"},
          {"linux", "arm64"},
          {"linux", "amd64"}
        ] do
      release_os = Map.get(@aqua_replacements, aqua_os, aqua_os)
      release_arch = Map.get(@aqua_replacements, aqua_arch, aqua_arch)

      rendered =
        template
        |> String.replace("{{.OS}}", release_os)
        |> String.replace("{{.Arch}}", release_arch)

      published = binary_asset_names(release_os)
      assert rendered in published
      assert "#{rendered}.sha256" in published
    end
  end
```

Generalize the existing producer helper without changing its current caller:

```elixir
  defp binary_asset_names(os \\ host_os()) do
```

Within that helper, replace the hard-coded `host_os()` interpolation with the
new `os` argument:

```elixir
        asset = "ecs-task-def-#{os}_#{arch}#{suffix}"
```

The first test deliberately checks the small registry contract as text instead
of adding a YAML parser dependency. The second test renders every supported
Aqua environment and compares the results with the producer-side asset helper,
including checksum sidecars. Task 2 separately proves YAML syntax and schema
validity.

- [ ] **Step 3: Run the focused test and verify the missing registry fails**

Run:

```bash
mise exec -- mix test test/release_tasks_test.exs
```

Expected: FAIL in the new local Aqua registry tests with `File.Error` because
`registry.yaml` does not exist. The existing release task tests should remain
green.

- [ ] **Step 4: Add the minimal repository-local registry**

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

- [ ] **Step 5: Run the focused test and verify it passes**

Run:

```bash
mise exec -- mix test test/release_tasks_test.exs
```

Expected: all tests in `test/release_tasks_test.exs` pass, including both new
offline registry contract tests.

- [ ] **Step 6: Check formatting and the intended diff**

Run:

```bash
mise exec -- mix format --check-formatted
git add -N registry.yaml
git diff --check
git status --short
git diff -- registry.yaml test/release_tasks_test.exs
```

Expected:

- formatting and whitespace checks pass;
- `registry.yaml` is visible in the unstaged diff through intent-to-add and
  `test/release_tasks_test.exs` is modified;
- the pre-existing `mise.lock` modification is still present but unchanged;
- no other implementation files changed.

---

### Task 2: Prove the Registry Through Isolated Aqua/mise Installation

**Files:**
- Verify: `registry.yaml`
- Verify: `mise.toml`
- Verify: `mise.lock`

**Interfaces:**
- Consumes: `registry.yaml` and public release `ecs-task-def@0.1.2`
- Produces: evidence that schema validation, mise parsing, version filtering, API-digest verification, installation, execution, and the independently published sidecar all satisfy the approved design without repository configuration mutation

- [ ] **Step 1: Validate YAML against the pinned Aqua schema from the disposable directory**

Run:

```bash
cd "$ECS_AQUA_VERIFY_DIR"
env \
  MISE_DATA_DIR="$ECS_AQUA_VERIFY_DIR/mise-data" \
  MISE_CACHE_DIR="$ECS_AQUA_VERIFY_DIR/mise-cache" \
  XDG_STATE_HOME="$ECS_AQUA_VERIFY_DIR/state" \
  XDG_CONFIG_HOME="$ECS_AQUA_VERIFY_DIR/xdg-config" \
  MISE_CONFIG_DIR="$ECS_AQUA_VERIFY_DIR/config" \
  MISE_GLOBAL_CONFIG_FILE="$ECS_AQUA_VERIFY_DIR/global.toml" \
  mise --no-config x pipx:check-jsonschema@0.36.2 -- \
  check-jsonschema \
  --schemafile https://raw.githubusercontent.com/aquaproj/aqua/v2.62.1/json-schema/registry.json \
  "$ECS_AQUA_REPO_ROOT/registry.yaml"
```

Expected: exit `0` with no schema validation errors. The exact one-off
`pipx:check-jsonschema@0.36.2` tool request is isolated under the disposable
mise data directory and does not enter the project lockfile.

- [ ] **Step 2: Load the local registry and verify its visible versions**

Run:

```bash
env \
  MISE_DATA_DIR="$ECS_AQUA_VERIFY_DIR/mise-data" \
  MISE_CACHE_DIR="$ECS_AQUA_VERIFY_DIR/mise-cache" \
  XDG_STATE_HOME="$ECS_AQUA_VERIFY_DIR/state" \
  XDG_CONFIG_HOME="$ECS_AQUA_VERIFY_DIR/xdg-config" \
  MISE_CONFIG_DIR="$ECS_AQUA_VERIFY_DIR/config" \
  MISE_GLOBAL_CONFIG_FILE="$ECS_AQUA_VERIFY_DIR/global.toml" \
  MISE_AQUA_REGISTRIES="$ECS_AQUA_REGISTRY_URL" \
  MISE_MINIMUM_RELEASE_AGE=0 \
  mise --no-config ls-remote aqua:djgoku/ecs-task-def \
  >"$ECS_AQUA_VERIFY_DIR/versions.txt"

(
  set -e
  grep -qxF "0.1.1" "$ECS_AQUA_VERIFY_DIR/versions.txt"
  grep -qxF "0.1.2" "$ECS_AQUA_VERIFY_DIR/versions.txt"

  if grep -qxF "0.1.0" "$ECS_AQUA_VERIFY_DIR/versions.txt"; then
    echo "broken 0.1.0 must not be visible" >&2
    exit 1
  fi
)
```

Expected: mise parses `registry.yaml`; `versions.txt` contains stripped
versions `0.1.1` and `0.1.2`, and contains no `0.1.0`.

- [ ] **Step 3: Install and execute `0.1.2` with GitHub API digest verification**

Run:

```bash
(
  set -e
  set -o pipefail
  env \
    MISE_DATA_DIR="$ECS_AQUA_VERIFY_DIR/mise-data" \
    MISE_CACHE_DIR="$ECS_AQUA_VERIFY_DIR/mise-cache" \
    XDG_STATE_HOME="$ECS_AQUA_VERIFY_DIR/state" \
    XDG_CONFIG_HOME="$ECS_AQUA_VERIFY_DIR/xdg-config" \
    MISE_CONFIG_DIR="$ECS_AQUA_VERIFY_DIR/config" \
    MISE_GLOBAL_CONFIG_FILE="$ECS_AQUA_VERIFY_DIR/global.toml" \
    MISE_AQUA_REGISTRIES="$ECS_AQUA_REGISTRY_URL" \
    MISE_MINIMUM_RELEASE_AGE=0 \
    mise -vv --no-config x aqua:djgoku/ecs-task-def@0.1.2 -- \
    ecs-task-def --help \
    2>&1 | tee "$ECS_AQUA_VERIFY_DIR/mise-install.log"

  grep -F "using GitHub API digest for checksum verification" \
    "$ECS_AQUA_VERIFY_DIR/mise-install.log"
)
```

Expected: the exact release installs as a raw executable, `ecs-task-def
--help` exits `0`, and the verbose log proves mise used the GitHub API's
per-asset digest. This validates mise's normal checksum path; it does not
exercise the registry checksum block's sidecar fallback.

- [ ] **Step 4: Verify the separately published SHA-256 sidecar**

Run:

```bash
(
  set -e

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

  cd "$ECS_AQUA_VERIFY_DIR/release-assets"
  shasum -a 256 -c "$ecs_aqua_asset.sha256"
)
```

Expected: both assets download and `shasum` reports
`<host asset name>: OK`. Together with schema validation, this independently
validates the declared sidecar's availability, name, and contents; mise's
fallback download path remains unforced.

- [ ] **Step 5: Run fail-fast repository verification and prove protected files are unchanged**

Run:

```bash
(
  set -euo pipefail
  cd "$ECS_AQUA_REPO_ROOT"

  mise exec -- mix format --check-formatted
  mise exec -- mix compile --warnings-as-errors
  mise exec -- mix test
  mise exec -- mix ecs.regen_schema --check
  git diff --check

  cmp "$ECS_AQUA_VERIFY_DIR/mise.toml.before" mise.toml
  cmp "$ECS_AQUA_VERIFY_DIR/mise.lock.before" mise.lock
  echo "mise.toml and mise.lock match their pre-mise baselines"
)
```

Expected:

- formatting, compilation, the complete ExUnit suite, schema regeneration
  drift check, and whitespace checks all pass;
- `mise.toml` and the already-dirty `mise.lock` match their byte-for-byte
  baseline copies.

- [ ] **Step 6: Stage, inspect, and commit only the registry implementation**

Run:

```bash
cd "$ECS_AQUA_REPO_ROOT"
git add registry.yaml test/release_tasks_test.exs
git diff --cached --check
git diff --cached --name-only
git commit -m "build: add local aqua registry"
git show --format= --name-only HEAD
```

Expected: the staged list and committed list contain exactly `registry.yaml`
and `test/release_tasks_test.exs`. The pre-existing `mise.lock` modification is
not staged or committed.

- [ ] **Step 7: Safely remove the disposable environment and inspect final status**

Run:

```bash
(
  set -e
  ecs_aqua_verify_name="$(basename -- "$ECS_AQUA_VERIFY_DIR")"

  case "$ecs_aqua_verify_name" in
    ecs-task-def-aqua.*)
      rm -rf -- "$ECS_AQUA_VERIFY_DIR"
      ;;
    *)
      echo "refusing to remove unexpected path: $ECS_AQUA_VERIFY_DIR" >&2
      exit 1
      ;;
  esac
)

unset ECS_AQUA_REGISTRY_URL
unset ECS_AQUA_VERIFY_DIR
unset ECS_AQUA_REPO_ROOT
git status --short
```

Expected: the disposable directory is removed, the implementation commit is
present, and only the user's pre-existing `mise.lock` change remains
uncommitted.
