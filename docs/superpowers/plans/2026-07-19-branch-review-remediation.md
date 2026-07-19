# Branch Review Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve all verified branch-review findings while preserving one reproducible local and GitHub release path.

**Architecture:** Make the two diagnostic fixes at their existing boundaries, keep the project mise toolchain limited to release dependencies, and add a standalone host-native Burrito smoke task that consumes artifacts from `mise run build`. GitHub Actions invokes the same smoke task developers run locally.

**Tech Stack:** Elixir 1.20.1-otp-29, Erlang/OTP 29.0.2, ExUnit, POSIX shell, mise 2026.7.0, Burrito 1.5.0, GitHub Actions

## Global Constraints

- `mise run build` remains the canonical release-binary build command.
- `mise run release-smoke` validates artifacts already produced by `mise run build`; it does not build them.
- The smoke task executes only the current host OS/CPU artifact.
- The smoke task must exercise `generate` with stdout connected to a pipe and validate the captured JSON.
- Pkl stderr read failures return an empty diagnostic string instead of raising.
- Duplicate-key warnings retain the key, both line numbers, and the winning line without exposing values.
- Claude is not part of the shared project toolchain.

---

### Task 1: Consistent Duplicate-Key Warning

**Files:**
- Modify: `test/ecs_task_def/env_file_test.exs:59-64`
- Modify: `lib/ecs_task_def/env_file.ex:31-39`

**Interfaces:**
- Consumes: `EcsTaskDef.EnvFile.parse/1`
- Produces: duplicate-key warning strings beginning with `warning:`

- [ ] **Step 1: Strengthen the existing test**

Replace the two substring assertions with an exact assertion that preserves the
path-sensitive part of the message:

```elixir
assert warning ==
         "warning: #{path}: duplicate key FOO on lines 1 and 3; using line 3"
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
mise exec -- mix test test/ecs_task_def/env_file_test.exs
```

Expected: one failure because the actual duplicate warning starts with the temp
file path rather than `warning:`.

- [ ] **Step 3: Add the warning prefix**

Change the duplicate warning in `EcsTaskDef.EnvFile.parse_lines/2` to:

```elixir
"warning: #{path}: duplicate key #{key} on lines #{prev_no} and #{no}; using line #{no}"
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```bash
mise exec -- mix test test/ecs_task_def/env_file_test.exs
```

Expected: all env-file tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/ecs_task_def/env_file.ex test/ecs_task_def/env_file_test.exs
git commit -m "fix: standardize duplicate env warnings"
```

---

### Task 2: Non-Raising Pkl Stderr Capture

**Files:**
- Modify: `test/support/fake_pkl.sh:2-26`
- Modify: `test/ecs_task_def/pkl_test.exs:25-38`
- Modify: `lib/ecs_task_def/pkl.ex:35`

**Interfaces:**
- Consumes: `EcsTaskDef.Pkl.eval(pkl_path, input_path, extra_env)`
- Produces: `{:error, {exit_code, ""}}` when the child exits nonzero but its stderr redirect file is absent
- Test control: `FAKE_PKL_REMOVE_STDERR_FILE=1` removes the open redirect path before fake Pkl exits

- [ ] **Step 1: Teach fake Pkl to simulate a missing redirect file**

Document the new control beside the existing environment variables:

```sh
#   FAKE_PKL_REMOVE_STDERR_FILE
#                     when 1, unlink the shell's stderr capture file
```

Before fake Pkl emits configured stderr/stdout, add:

```sh
if [ "$FAKE_PKL_REMOVE_STDERR_FILE" = "1" ]; then
  rm -f "$ECS_TASK_DEF_STDERR_FILE"
fi
```

- [ ] **Step 2: Add the regression test**

Add to `EcsTaskDef.PklTest`:

```elixir
test "missing stderr capture file falls back to an empty diagnostic" do
  assert {:error, {42, ""}} =
           Pkl.eval(fake_pkl(), "ignored.pkl", [
             {"FAKE_PKL_REMOVE_STDERR_FILE", "1"},
             {"FAKE_PKL_EXIT", "42"}
           ])
end
```

- [ ] **Step 3: Run the regression test and verify RED**

Run:

```bash
mise exec -- mix test test/ecs_task_def/pkl_test.exs
```

Expected: the new test raises `File.Error` from `File.read!/1` because the fake
child unlinked the capture file.

- [ ] **Step 4: Make the stderr read non-raising**

Replace `File.read!/1` with:

```elixir
stderr =
  case File.read(stderr_file) do
    {:ok, contents} -> contents
    {:error, _reason} -> ""
  end
```

Do not change the exit-code branches or the `after` cleanup.

- [ ] **Step 5: Run the focused test and verify GREEN**

Run:

```bash
mise exec -- mix test test/ecs_task_def/pkl_test.exs
```

Expected: all fake and real Pkl tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/ecs_task_def/pkl.ex test/ecs_task_def/pkl_test.exs test/support/fake_pkl.sh
git commit -m "fix: tolerate missing Pkl stderr capture"
```

---

### Task 3: Remove Claude from the Project Toolchain

**Files:**
- Modify: `mise.toml:1-3`
- Modify: `mise.lock:158-188`

**Interfaces:**
- Consumes: project-local `mise.toml`
- Produces: a project tool list and lockfile containing only build, test,
  package, and release dependencies

- [ ] **Step 1: Capture the failing toolchain contract**

Run:

```bash
if rg -q '^claude\s*=' mise.toml; then
  echo "claude is unexpectedly present in the project toolchain" >&2
  exit 1
fi
```

Expected: exit `1` and the diagnostic because `mise.toml` currently declares
Claude.

- [ ] **Step 2: Remove the Claude tool declaration**

Delete the `claude = { ... }` line from `[tools]` in `mise.toml`. Keep Erlang,
Elixir, Pkl, Zig, xz-tools, xz, and 7zip unchanged.

- [ ] **Step 3: Remove only Claude from the project lockfile**

Delete the contiguous Claude section in `mise.lock`, beginning with:

```toml
[[tools.claude]]
```

and ending with the `tools.claude.platforms.windows-x64` table immediately before:

```toml
[[tools."conda:xz"]]
```

This removes the `[[tools.claude]]` entry and all seven
`[tools.claude."platforms.*"]` tables. Do not run `mise lock`: a full refresh
rewrites unrelated platform metadata, including the deliberately unresolved
`conda:xz-tools` entries documented by the CI workflows.

- [ ] **Step 4: Verify the toolchain contract**

Run:

```bash
if rg -q '^claude\s*=' mise.toml; then
  echo "claude is unexpectedly present in the project toolchain" >&2
  exit 1
fi
rg -n 'tools\.claude|claude-code' mise.toml mise.lock && exit 1 || true
mise install --dry-run
```

Expected: no Claude match and a successful dry-run without a Claude download.

- [ ] **Step 5: Review lockfile scope and commit**

Run:

```bash
git diff -- mise.toml mise.lock
```

Expected: only the Claude declaration and Claude lock tables are removed.

Additionally run:

```bash
git diff --numstat -- mise.toml mise.lock
```

Expected:

```text
0	32	mise.lock
0	1	mise.toml
```

Any added or otherwise changed lines indicate unrelated lockfile churn and must
be reverted before committing.

Then:

```bash
git add mise.toml mise.lock
git commit -m "build: remove Claude from project toolchain"
```

---

### Task 4: Reusable Host-Native Release Smoke Task

**Files:**
- Modify: `mise.toml:37`
- Modify: `.github/workflows/release.yml:65-68`

**Interfaces:**
- Consumes: executable `burrito_out/ecs_task_def_<host-os>_<host-arch>` produced by `mise run build`
- Produces: `mise run release-smoke`, exiting zero only when help works and piped `generate` output is valid JSON with family `my-app`

- [ ] **Step 1: Verify the task is absent**

Run:

```bash
mise task info release-smoke
```

Expected: nonzero exit with `Task not found: release-smoke`.

- [ ] **Step 2: Add the standalone smoke task**

Append to `mise.toml`:

```toml
[tasks.release-smoke]
description = "Smoke-test the host-native Burrito release binary"
run = """
set -eu

case "$(uname -s)" in
  Darwin) release_os=macos ;;
  Linux) release_os=linux ;;
  *)
    echo "release-smoke: unsupported host OS: $(uname -s) (expected Darwin or Linux)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  arm64|aarch64) release_arch=aarch64 ;;
  x86_64|amd64) release_arch=x86_64 ;;
  *)
    echo "release-smoke: unsupported host architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

binary="$PWD/burrito_out/ecs_task_def_${release_os}_${release_arch}"
if [ ! -x "$binary" ]; then
  echo "release-smoke: expected executable $binary; run 'mise run build' first" >&2
  exit 1
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ecs-task-def-release-smoke.XXXXXX")"
trap 'rm -rf "$tmp_dir"' 0

"$binary" --help >/dev/null
"$binary" init "$tmp_dir/project" --vendor >/dev/null

output="$tmp_dir/task.json"
status_file="$tmp_dir/generate.status"
(
  set +e
  ECR_REPO=example.invalid/my-app IMAGE_TAG=smoke \
    "$binary" generate "$tmp_dir/project/mytask.pkl"
  status=$?
  set -e
  printf '%s\n' "$status" >"$status_file"
) | cat >"$output"

generate_status="$(cat "$status_file")"
if [ "$generate_status" -ne 0 ]; then
  echo "release-smoke: generate exited $generate_status" >&2
  exit "$generate_status"
fi

elixir -e 'path = hd(System.argv()); data = path |> File.read!() |> JSON.decode!(); unless data["family"] == "my-app", do: System.halt(1)' "$output"
echo "release-smoke: passed $binary"
"""
```

- [ ] **Step 3: Register the task in the release workflow**

Immediately after the existing build step, add:

```yaml
      - name: Smoke-test the host-native release binary
        run: mise run release-smoke
```

- [ ] **Step 4: Verify task metadata and workflow formatting**

Run:

```bash
mise task info release-smoke
git diff --check
```

Expected: task info shows the host-native smoke command, and the diff has no
whitespace errors.

- [ ] **Step 5: Run the smoke task against current artifacts**

Run:

```bash
mise run release-smoke
```

Expected on this host: the macOS aarch64 binary prints progress on stderr, the
pipe captures complete JSON, JSON validation succeeds, and the task reports
`release-smoke: passed`.

- [ ] **Step 6: Commit**

```bash
git add mise.toml .github/workflows/release.yml
git commit -m "ci: smoke-test release binary stdout"
```

---

### Task 5: Full Verification

**Files:**
- Verify only; no expected source changes

**Interfaces:**
- Consumes: all four remediation commits
- Produces: evidence that tests, release compilation, the real Pkl path, and the
  host-native piped stdout path all pass together

- [ ] **Step 1: Run formatting and compilation checks**

Run:

```bash
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
```

Expected: both commands exit `0`.

- [ ] **Step 2: Run the complete test suite**

Run:

```bash
mise exec -- mix test
```

Expected: all tests pass, including tests tagged `:pkl`.

- [ ] **Step 3: Rebuild both host-OS release artifacts**

Run:

```bash
mise run build
```

Expected: Burrito builds both CPU artifacts for the host OS.

- [ ] **Step 4: Run the smoke task against the fresh native artifact**

Run:

```bash
mise run release-smoke
```

Expected: help, init, piped generation, and JSON validation all succeed.

- [ ] **Step 5: Inspect final branch state**

Run:

```bash
git status --short
git log --oneline -6
```

Expected: a clean worktree and the design, warning, stderr, toolchain, and smoke
commits at the branch tip.
