# Apple Container Knowledge-Base Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record the verified Apple Container 1.1.0 upgrade/service mismatch and recovery procedure in all relevant personal knowledge-base files.

**Architecture:** Treat `apple-container.md` as the evidence-bearing source of truth, add one concise mise cross-reference for the general service-backed aqua upgrade rule, and keep `index.md` as a current summary. Update all three together so no stale 1.0.0 “latest” claim survives.

**Tech Stack:** Markdown, ripgrep, GitHub CLI, mise, Apple Container 1.1.0

## Global Constraints

- Edit only `~/.claude/knowledge-base/apple-container.md`, `mise.md`, and `index.md`.
- Preserve existing validated facts that are not superseded.
- Every new operational claim must include the command or observed output that proved it.
- Name Apple Container 1.1.0 as published on 2026-07-06.
- Distinguish the signed Apple installer from the validated aqua/mise installation path.
- Record that an aqua upgrade does not restart an already-running launchd service.
- Record the exact stale-service diagnosis and explicit-version stop/start recovery.
- These personal knowledge-base files are not in a Git repository, so do not create a Git commit for them.

---

### Task 1: Refresh the Apple Container Source Note

**Files:**
- Modify: `/Users/dj_goku/.claude/knowledge-base/apple-container.md`

**Interfaces:**
- Consumes: official release metadata and the reproduced 1.0.0-service/1.1.0-CLI incident
- Produces: the complete evidence-bearing Apple Container operational note

- [ ] **Step 1: Confirm the stale claims and capture the current proof**

Run:

```bash
mkdir -p /private/tmp/apple-container-kb-baseline
touch /private/tmp/apple-container-kb-baseline/start-marker
cp /Users/dj_goku/.claude/knowledge-base/apple-container.md \
  /private/tmp/apple-container-kb-baseline/apple-container.md
cp /Users/dj_goku/.claude/knowledge-base/mise.md \
  /private/tmp/apple-container-kb-baseline/mise.md
cp /Users/dj_goku/.claude/knowledge-base/index.md \
  /private/tmp/apple-container-kb-baseline/index.md

rg -n 'Latest = \\*\\*1\\.0\\.0|NOT via mise|container 1\\.0' \
  /Users/dj_goku/.claude/knowledge-base/apple-container.md
gh release view 1.1.0 --repo apple/container \
  --json tagName,publishedAt,name,url
mise where aqua:apple/container
mise x -- container --version
mise x -- container system status
```

Expected:

- the note contains the stale 1.0.0/latest and contradictory installation wording;
- GitHub reports tag `1.1.0`, published `2026-07-06`;
- mise and both current Apple Container components resolve to 1.1.0 after repair.

- [ ] **Step 2: Replace the version and installation section**

Replace the existing `## Version / release` section with:

```markdown
## Version / release (VALIDATED via GitHub releases API, 2026-07-19)
- Latest checked = **1.1.0**, published **2026-07-06**. Proof:
  `gh release view 1.1.0 --repo apple/container --json
  tagName,publishedAt,name,url` returned tag/name `1.1.0` and
  `2026-07-06T19:47:13Z`.
- 1.0.0 was the breaking successor to 0.12.3: TOML `config.toml` replaced
  UserDefaults-backed `container system property get/set`, v0 XPC compatibility
  was removed, and `container machine` plus `container cp` were added.
- Apple publishes a signed `.pkg` installer. A validated alternative is
  `aqua:apple/container` through mise; both installations use the same
  `~/Library/Application Support/com.apple.container` data directory, so images,
  containers, and networks survive a CLI-source switch.
- When the aqua package is configured as `latest`, mise can install a newer CLI
  while an already-running launchd service keeps executing the old
  `container-apiserver`. Restart the service after an upgrade and verify CLI/API
  versions plus `installRoot` before running containers.
```

- [ ] **Step 3: Add the reproduced mismatch and recovery section**

Insert before `## Bottom line for "can I drop colima?"`:

```markdown
## mise/aqua upgrade can leave a stale running service (VALIDATED 2026-07-19)
- Reproduced during a 1.0.0 → 1.1.0 aqua upgrade. `mise where
  aqua:apple/container` selected
  `~/.local/share/mise/installs/aqua-apple-container/1.1.0`, but
  `container --version` and `container system status` still reported 1.0.0.
  Status exposed the stale, subsequently removed install root
  `~/.local/share/mise/installs/aqua-apple-container/1.0.0/Payload/`.
- Symptom: `container run ... ubuntu:24.04 ...` remained at `Starting container`;
  `container logs <id>` failed because `stdio.log` did not exist. The guest
  process had never started, so changing the image command or mount could not
  fix it.
- Recovery: select one installed version explicitly for both lifecycle calls:

  ```console
  mise x aqua:apple/container@1.1.0 -- container system stop
  mise x aqua:apple/container@1.1.0 -- container system start
  mise x aqua:apple/container@1.1.0 -- container system status
  mise x aqua:apple/container@1.1.0 -- container --version
  ```

  After restart, CLI and API server both reported 1.1.0 and `installRoot` named
  the existing `.../1.1.0/Payload/`.
- Runtime proof: `container run --rm --arch arm64 ubuntu:24.04 uname -a` exited
  zero. A second run using the official Elixir 1.20/OTP 29 Linux image completed
  the real project command `mix ecs.regen_schema --check` with
  `regen check: all artifacts up to date`.
- Diagnostic rule: compare `container --version`, `container system status`
  (`apiserver.version` and `installRoot`), and `mise where
  aqua:apple/container`. If they disagree, restart with one explicit mise
  version before investigating image, network, or mount behavior.
```

- [ ] **Step 4: Refresh dated 1.0.0 references without erasing historical proof**

Change current-summary phrases such as `apple/container 1.0 can replace colima`
to `apple/container 1.1 can replace colima`. Keep explicitly historical lines
that describe the 2026-06-19 test as having used 1.0.0.

- [ ] **Step 5: Validate the source note**

Run:

```bash
rg -n '1\\.1\\.0|stale running service|stdio\\.log|installRoot|system stop|system start|regen check' \
  /Users/dj_goku/.claude/knowledge-base/apple-container.md
rg -n 'Latest = \\*\\*1\\.0\\.0|Latest = \\*\\*1\\.0|NOT via mise|apple/container 1\\.0 can' \
  /Users/dj_goku/.claude/knowledge-base/apple-container.md
```

Expected: the first scan finds the new evidence and recovery; the second has no matches.

---

### Task 2: Add the General mise Upgrade Rule and Refresh the Index

**Files:**
- Modify: `/Users/dj_goku/.claude/knowledge-base/mise.md`
- Modify: `/Users/dj_goku/.claude/knowledge-base/index.md`

**Interfaces:**
- Consumes: the evidence-bearing `apple-container.md` update from Task 1
- Produces: a general mise warning plus a current index summary

- [ ] **Step 1: Add a service-backed aqua warning to `mise.md`**

Append this bullet under the aqua backend section:

```markdown
- **Upgrading a service-backed aqua tool does not restart its already-running
  service.** Reproduced with `aqua:apple/container` 1.0.0 → 1.1.0: mise selected
  the 1.1.0 install while launchd kept the 1.0.0 `container-apiserver` running
  from an `installRoot` that mise had removed; every container then hung before
  guest execution. Stop and start the service through the same explicit tool
  version, then compare CLI version, service version, and install root. Full
  commands and evidence: [apple-container.md](apple-container.md).
```

- [ ] **Step 2: Replace the Apple Container index summary**

Replace the existing `apple-container.md` index bullet with:

```markdown
- [apple-container.md](apple-container.md) — apple/container vs colima:
  native per-container VMs with its own CLI/XPC API and no Docker socket;
  macOS-26/Apple-Silicon requirements, Rosetta amd64, networking, and Docker API
  gaps; **latest checked = 1.1.0 (2026-07-06)**; signed installer and validated
  aqua/mise installation share one data directory; **mise upgrade trap:
  installed CLI can advance while the old launchd service keeps a removed
  `installRoot` → containers hang at startup; restart with one explicit version
  and verify CLI/API/installRoot alignment**.
```

- [ ] **Step 3: Validate all cross-references and stale-claim removal**

Run:

```bash
rg -n 'service-backed aqua|apple-container\\.md' \
  /Users/dj_goku/.claude/knowledge-base/mise.md
rg -n 'latest checked = 1\\.1\\.0|mise upgrade trap|installRoot' \
  /Users/dj_goku/.claude/knowledge-base/index.md
rg -n 'Latest = \\*\\*1\\.0\\.0|Latest = \\*\\*1\\.0|Latest = 1\\.0\\.0|Latest = 1\\.0' \
  /Users/dj_goku/.claude/knowledge-base/apple-container.md \
  /Users/dj_goku/.claude/knowledge-base/mise.md \
  /Users/dj_goku/.claude/knowledge-base/index.md
```

Expected: the first two scans find the new cross-references; the stale latest-version scan has no matches.

---

### Task 3: Final Knowledge-Base Review

**Files:**
- Verify: `/Users/dj_goku/.claude/knowledge-base/apple-container.md`
- Verify: `/Users/dj_goku/.claude/knowledge-base/mise.md`
- Verify: `/Users/dj_goku/.claude/knowledge-base/index.md`

**Interfaces:**
- Consumes: Tasks 1-2
- Produces: a consistent, evidence-backed personal knowledge base

- [ ] **Step 1: Inspect the complete diffs against temporary baselines**

Before editing, execution must save read-only baseline copies under
`/private/tmp/apple-container-kb-baseline/`. After editing, run:

```bash
diff -u /private/tmp/apple-container-kb-baseline/apple-container.md \
  /Users/dj_goku/.claude/knowledge-base/apple-container.md
diff -u /private/tmp/apple-container-kb-baseline/mise.md \
  /Users/dj_goku/.claude/knowledge-base/mise.md
diff -u /private/tmp/apple-container-kb-baseline/index.md \
  /Users/dj_goku/.claude/knowledge-base/index.md
```

Expected: only the approved version, upgrade/recovery, cross-reference, and index-summary changes appear.

- [ ] **Step 2: Check Markdown structure and file scope**

Run:

```bash
rg -n '^# |^## ' /Users/dj_goku/.claude/knowledge-base/apple-container.md
find /Users/dj_goku/.claude/knowledge-base -type f -newer \
  /private/tmp/apple-container-kb-baseline/start-marker -print
```

Expected: headings remain well-formed; only the three approved knowledge-base files are newer than the baseline marker.

- [ ] **Step 3: Report completion without a Git commit**

Report the three updated absolute paths, the evidence recorded, and the stale-version scan result. Do not run `git add` or `git commit`: `~/.claude/knowledge-base` is not a Git worktree.
