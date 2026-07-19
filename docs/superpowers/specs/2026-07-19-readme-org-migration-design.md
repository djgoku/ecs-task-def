# README Org Migration Design

## Goal

Replace `README.md` with `README.org` while preserving the current content,
commands, ordering, and meaning.

## Approach

Use `git mv README.md README.org` so Git records the migration as a rename.
Convert the document manually instead of using an automated converter, keeping
the diff controlled and avoiding prose reflow.

Convert Markdown constructs to GitHub-compatible Org syntax:

- headings to leading `*` characters;
- links to `[[URL][label]]`;
- inline code to `~code~`;
- bold text to `*text*` and italic text to `/text/`;
- fenced code blocks to `#+begin_src LANGUAGE` and `#+end_src`;
- the exit-code table separator to Org table syntax.

The migration is format-only. Do not revise claims, commands, examples, prose,
or release guidance. Preserve existing line wrapping wherever practical.

## Repository References

Delete no historical documentation references. Existing Superpowers plans that
mention `README.md` describe the file path at the time those plans were
executed, so they remain unchanged.

## Validation

- Parse and lint `README.org` with Org mode.
- Scan for leftover Markdown headings, fenced blocks, links, and emphasis.
- Inspect the Git diff to confirm the change is recognized as a rename and that
  wording is preserved.
- Confirm `README.md` no longer exists and `README.org` is the sole primary
  README.
- Commit the migration as one documentation commit.
- Perform one final review of the branch after the conversion commit.

## Alternatives Considered

Pandoc could automate the conversion, but it may reflow content and introduce a
larger, harder-to-review diff. Renaming without syntax conversion would leave a
file that GitHub cannot render correctly as Org. A manual semantic conversion
best preserves the document and its history.
