# Branch Review Remediation Design

## Context

The branch review found four actionable issues:

1. The project toolchain includes Claude even though Claude is not needed to build,
   test, or release the project.
2. Pkl stderr capture uses `File.read!/1`, so an absent redirect file can turn a
   command failure into an unrelated exception.
3. Duplicate env-file key diagnostics do not use the same `warning:` prefix as
   other warnings.
4. The release workflow builds Burrito binaries but does not exercise the
   top-level `System.halt/1` path while stdout is connected to a pipe.

## Design

### Project toolchain

Remove the Claude entry from `mise.toml` and surgically delete only Claude's
tables from `mise.lock`. Do not run a full `mise lock`: it refreshes unrelated
platform metadata, including the deliberately unresolved `conda:xz-tools`
entries documented by the CI workflows. The shared toolchain should contain only
tools required to build, test, package, or release the project.

### Safe stderr capture

Replace the raising stderr-file read with a non-raising read. Successful reads
return their contents; a missing or unreadable file falls back to an empty
string. Existing exit-code behavior remains unchanged, and the temporary file is
still removed in the `after` block.

### Warning consistency

Prefix duplicate env-file key messages with `warning:`. The warning continues to
identify the key, both line numbers, and the winning line without exposing any
values.

### Release binary smoke check

Add a separate `mise run release-smoke` task. It depends on neither compilation
nor release creation; callers run it against artifacts already produced by
`mise run build`.

The task selects the binary matching the current host OS and CPU architecture,
runs a basic help check, scaffolds a fresh vendored project with `init --vendor`,
generates JSON from that project with stdout piped through `cat`, and validates
the captured output with the project-pinned Elixir runtime. Selecting only the
native artifact avoids trying to execute the second cross-compiled binary.

The GitHub release workflow runs `mise run release-smoke` immediately after
`mise run build`. Developers can run the same two commands locally, preserving
local/CI parity.

## Testing

- Change the duplicate-warning assertion first and confirm it fails before the
  implementation change.
- Add the release-smoke task and confirm its contract against freshly built
  Burrito artifacts.
- Run focused Pkl and env-file tests.
- Run the complete Mix test suite.
- Run `mise run build` followed by `mise run release-smoke`.
- Confirm the lockfile diff removes only Claude and `mise install --dry-run` no
  longer resolves or installs it.

## Alternatives Considered

Embedding the smoke check in `mise run build` would make build and validation
less composable. Keeping the check only in GitHub Actions would prevent
developers from reproducing the release path locally. A separate mise task,
explicitly invoked in both environments, provides the clearest shared contract.
