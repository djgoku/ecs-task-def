# Preserve Pkl Error Colors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve Pkl's ANSI-colored error diagnostics when the CLI captures and replays Pkl stderr.

**Architecture:** Keep the existing stdout/stderr separation and temporary-file capture. Force Pkl's formatter to retain ANSI sequences by adding `--color=always` to the existing `pkl eval` arguments, and verify the exact child-process contract with the configurable fake Pkl executable.

**Tech Stack:** Elixir, ExUnit, POSIX shell, Pkl CLI 0.31.1+

## Global Constraints

- Generated JSON on stdout must remain unchanged.
- The CLI's own progress and error formatting must remain unchanged.
- Pkl diagnostics must remain always colored even when stderr is redirected or piped.
- Do not add a runtime dependency or a second diagnostic-formatting path.

---

### Task 1: Preserve Pkl Diagnostic Colors

**Files:**
- Modify: `test/support/fake_pkl.sh:2-13`
- Test: `test/ecs_task_def/pkl_test.exs:31-35`
- Modify: `lib/ecs_task_def/pkl.ex:2-23`

**Interfaces:**
- Consumes: `EcsTaskDef.Pkl.eval(pkl_path, input_path, extra_env) :: {:ok, stdout, stderr} | {:error, {exit_code, stderr}}`
- Produces: the same `EcsTaskDef.Pkl.eval/3` return contract, with `--color=always` included in the spawned Pkl eval arguments

- [ ] **Step 1: Teach the fake Pkl executable to assert the color argument**

Add the new environment variable to the fixture documentation:

```sh
#   FAKE_PKL_REQUIRE_COLOR_ALWAYS
#                     when 1, fail unless --color=always is present
```

After the `--version` branch, add:

```sh
if [ "$FAKE_PKL_REQUIRE_COLOR_ALWAYS" = "1" ]; then
  found_color_always=
  for arg do
    [ "$arg" = "--color=always" ] && found_color_always=1
  done

  if [ "$found_color_always" != "1" ]; then
    printf '%s\n' "missing --color=always" >&2
    exit 97
  fi
fi
```

- [ ] **Step 2: Write the failing child-command test**

Add this test after `"extra_env reaches the child process"` in
`test/ecs_task_def/pkl_test.exs`:

```elixir
test "forces Pkl diagnostics to retain ANSI colors" do
  assert {:ok, _out, _stderr} =
           Pkl.eval(fake_pkl(), "ignored.pkl", [{"FAKE_PKL_REQUIRE_COLOR_ALWAYS", "1"}])
end
```

- [ ] **Step 3: Run the focused test and verify RED**

Run:

```bash
mise exec -- mix test test/ecs_task_def/pkl_test.exs
```

Expected: FAIL in `"forces Pkl diagnostics to retain ANSI colors"` because
the fake exits `97` and returns stderr containing `missing --color=always`.

- [ ] **Step 4: Add the minimal Pkl invocation change**

Update the module documentation's command description:

```elixir
Spawns `pkl eval --color=always -f json INPUT` with the merged environment
and captures stdout (the JSON) and stderr (diagnostics) separately.
```

Format the `System.cmd/3` argument list and include the color option:

```elixir
[
  "-c",
  ~S(exec "$0" "$@" 2>"$ECS_TASK_DEF_STDERR_FILE"),
  pkl_path,
  "eval",
  "--color=always",
  "-f",
  "json",
  input_path
]
```

- [ ] **Step 5: Run focused and related tests and verify GREEN**

Run:

```bash
mise exec -- mix test test/ecs_task_def/pkl_test.exs test/ecs_task_def/cli_test.exs
```

Expected: all Pkl and CLI tests pass.

- [ ] **Step 6: Run formatting and the complete test suite**

Run:

```bash
mise exec -- mix format --check-formatted
mise exec -- mix test
```

Expected: formatting check exits `0`; the complete test suite passes with no
failures.

- [ ] **Step 7: Commit the implementation**

```bash
git add test/support/fake_pkl.sh test/ecs_task_def/pkl_test.exs lib/ecs_task_def/pkl.ex docs/superpowers/plans/2026-07-18-preserve-pkl-error-colors.md
git commit -m "fix: preserve Pkl diagnostic colors"
```
