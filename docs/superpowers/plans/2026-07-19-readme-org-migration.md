# README Org Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `README.md` with a semantically equivalent, GitHub-renderable `README.org`.

**Architecture:** Preserve Git history with `git mv`, then manually translate only documentation syntax so prose and commands remain unchanged. Validate the result structurally with Org mode, mechanically for leftover Markdown, and semantically by comparing Pandoc plain-text renderings.

**Tech Stack:** Git, Org mode, Emacs, ripgrep, Pandoc

## Global Constraints

- `README.org` fully replaces `README.md`.
- The migration is format-only: preserve claims, commands, examples, ordering, and meaning.
- Preserve existing line wrapping wherever Org syntax permits.
- Leave historical plan references to `README.md` unchanged.
- Commit the conversion as one documentation commit.
- Perform one final branch review after the conversion commit.

---

### Task 1: Rename and Convert the Primary README

**Files:**
- Rename: `README.md` to `README.org`

**Interfaces:**
- Consumes: the complete 187-line Markdown document at `README.md`
- Produces: a single primary `README.org` rendered with GitHub-compatible Org syntax

- [ ] **Step 1: Verify the migration contract is initially RED**

Run:

```bash
test -f README.org && test ! -e README.md
```

Expected: exit nonzero because `README.md` exists and `README.org` does not.

- [ ] **Step 2: Record a semantic baseline from the committed Markdown**

Run:

```bash
pandoc -f gfm -t plain README.md
```

Expected: plain-text output containing the `ecs-task-def` title, installation,
usage, exit codes, contributing instructions, and releasing guidance without
conversion errors.

- [ ] **Step 3: Rename the README through Git**

Run:

```bash
git mv README.md README.org
```

Expected: `git status --short` reports `R  README.md -> README.org` before the
content conversion lowers Git's similarity score.

- [ ] **Step 4: Convert headings**

Apply these exact heading mappings:

```text
# ecs-task-def
→ * ecs-task-def

## Installation
→ ** Installation

### Prerequisite: the Pkl CLI
→ *** Prerequisite: the Pkl CLI

## Usage
→ ** Usage

### `ecs-task-def init [DIR] [--vendor]`
→ *** ~ecs-task-def init [DIR] [--vendor]~

### `ecs-task-def generate INPUT.pkl [--output|-o PATH] [--env-file PATH]`
→ *** ~ecs-task-def generate INPUT.pkl [--output|-o PATH] [--env-file PATH]~

### `.env` files and environment precedence
→ *** ~.env~ files and environment precedence

### Help
→ *** Help

## Exit codes
→ ** Exit codes

## Contributing
→ ** Contributing

### Releasing
→ *** Releasing
```

- [ ] **Step 5: Convert links, emphasis, and inline code**

Convert the four Markdown links exactly:

```text
[Pkl](https://pkl-lang.org)
→ [[https://pkl-lang.org][Pkl]]

[amazon-ecs-intellisense-schema](https://github.com/awslabs/amazon-ecs-intellisense-schema)
→ [[https://github.com/awslabs/amazon-ecs-intellisense-schema][amazon-ecs-intellisense-schema]]

[Burrito](https://github.com/burrito-elixir/burrito)
→ [[https://github.com/burrito-elixir/burrito][Burrito]]

[GitHub Releases](https://github.com/djgoku/aws-ecs-task-definition-generator/releases)
→ [[https://github.com/djgoku/aws-ecs-task-definition-generator/releases][GitHub Releases]]
```

Convert every remaining Markdown inline-code span from backticks to Org verbatim
markers:

```text
`text`
→ ~text~
```

Convert emphasis without changing its words:

```text
**text**
→ *text*

*different*
→ /different/
```

Keep each emphasized phrase on one physical line where Org requires it. In
particular, reflow `No release has been published yet` onto one emphasized line
without changing the sentence.

- [ ] **Step 6: Convert code blocks**

Convert each `console` fence:

````text
```console
````

to `#+begin_src console`, and replace its matching closing fence:

````text
```
````

with `#+end_src`. Keep every line between those delimiters byte-for-byte
unchanged.

Convert the unlabelled warning example:

````text
```
warning: IMAGE_TAG is set in both the environment and .env.production with different values; using the environment value
```
````

to:

```text
#+begin_src text
warning: IMAGE_TAG is set in both the environment and .env.production with different values; using the environment value
#+end_src
```

- [ ] **Step 7: Convert the exit-code table separator**

Replace:

```text
|---|---|
```

with:

```text
|------+---------|
```

Keep every header and data cell unchanged.

- [ ] **Step 8: Verify the migration contract is GREEN**

Run:

```bash
test -f README.org
test ! -e README.md
```

Expected: both commands exit `0`.

- [ ] **Step 9: Scan for leftover Markdown syntax**

Run:

```bash
if rg -n '^```|^#{2,6} |^# ecs-task-def$|\[[^]]+\]\(https?://|\*\*[^*]+\*\*|`[^`]+`' README.org; then
  echo "README.org still contains Markdown syntax" >&2
  exit 1
fi
```

Expected: no matches and exit `0`. The console comment `# or` is intentionally
not treated as a Markdown heading.

- [ ] **Step 10: Parse and lint with Org mode**

Run:

```bash
emacs_bin="$(mise which emacs)"
"$emacs_bin" --batch README.org --eval '(progn (require (quote org)) (org-mode) (let ((issues (org-lint))) (when issues (princ issues) (kill-emacs 1))))'
```

Expected: exit `0` with no Org lint issues.

- [ ] **Step 11: Compare semantic renderings**

Run:

```bash
diff -u \
  <(git show HEAD:README.md | pandoc -f gfm -t plain) \
  <(pandoc -f org -t plain README.org)
```

Expected: no semantic text differences and exit `0`. If Pandoc formats the Org
table separator differently, inspect that isolated rendering difference and
confirm all header and data cells are unchanged.

- [ ] **Step 12: Inspect rename and content scope**

Run:

```bash
git diff --check
git diff --summary --find-renames
git diff --word-diff=color --find-renames -- README.md README.org
```

Expected:

- no whitespace errors;
- a rename from `README.md` to `README.org`;
- only Markdown-to-Org delimiters and the necessary emphasized-line reflow
  differ at the word level.

- [ ] **Step 13: Commit the conversion**

```bash
git add README.org
git commit -m "docs: migrate README to Org"
```

---

### Task 2: Final Branch Review and Verification

**Files:**
- Review: all changes from `main...HEAD`
- Verify: `README.org`

**Interfaces:**
- Consumes: the committed README migration and all existing branch changes
- Produces: a severity-ranked final review and fresh verification evidence

- [ ] **Step 1: Review the committed README migration**

Run:

```bash
git show --stat --summary HEAD
git show --word-diff=color --find-renames HEAD -- README.md README.org
```

Expected: one README rename commit with format-only changes.

- [ ] **Step 2: Review the complete branch diff**

Run:

```bash
git diff --stat main...HEAD
git diff --check HEAD^..HEAD
git log --oneline main..HEAD
```

Inspect the complete branch for correctness, regressions, missing tests, unsafe
release behavior, stale documentation, and deviations from the approved specs.
Report findings by severity with file and line references; do not modify code
until each finding is technically verified.

- [ ] **Step 3: Re-run documentation validation**

Run:

```bash
emacs_bin="$(mise which emacs)"
"$emacs_bin" --batch README.org --eval '(progn (require (quote org)) (org-mode) (let ((issues (org-lint))) (when issues (princ issues) (kill-emacs 1))))'
```

Expected: exit `0` with no Org lint issues.

- [ ] **Step 4: Run the complete test suite**

Run:

```bash
mise exec -- mix test
```

Expected: all tests pass, including real Pkl integration tests.

- [ ] **Step 5: Re-run the release pipe smoke**

Run:

```bash
mise run release-smoke
```

Expected: the host-native Burrito binary completes help, vendored init, piped
generation, producer-status capture, and JSON validation.

- [ ] **Step 6: Confirm final repository state**

Run:

```bash
git status --short
git log --oneline -8
```

Expected: a clean worktree with the README migration commit at `HEAD`.
