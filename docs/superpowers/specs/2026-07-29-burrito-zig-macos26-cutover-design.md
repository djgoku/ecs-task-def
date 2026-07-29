# Burrito, Zig, and macOS 26 Focused Cutover Design

## Goal

Upgrade the release toolchain from Burrito 1.5.0 and Zig 0.15.2 to Burrito
1.6.0 and Zig 0.16.0, run macOS CI and release builds on macOS 26, and remove
the compatibility code and active documentation that existed only for the old
toolchain.

Burrito 1.6.0 was tagged and published on 2026-07-24. Its changelog states
that it adds Zig 0.16.0 compatibility, and its source requires Zig 0.16.0.

## Scope

This cutover will:

- change the Hex dependency constraint from Burrito `~> 1.5` to `~> 1.6` and
  resolve `mix.lock` to Burrito 1.6.0;
- change the mise Zig pin from 0.15.2 to 0.16.0 and regenerate `mise.lock`;
- change active macOS GitHub Actions jobs from `macos-15` to `macos-26`;
- stop prepending the repository's `bin` directory during macOS builds;
- delete the obsolete `bin/xcrun` SDK-selection shim;
- update active comments and README text that name Burrito 1.5, Zig 0.15.2,
  the macOS 26 SDK incompatibility, or the shim; and
- preserve the existing two-target-per-host build, artifact naming, smoke
  testing, checksum, and release-publishing behavior.

Historical documents under `docs/superpowers/specs` and
`docs/superpowers/plans` will not be rewritten. They accurately describe the
constraints and decisions in effect when their work was performed. This new
design records why the old workaround is being removed.

Updating unrelated Elixir dependencies, other mise tools, or GitHub Actions
versions is explicitly deferred until this cutover is complete and assessed.

## Design

### Dependency and toolchain pins

`mix.exs` will require `{:burrito, "~> 1.6"}`. A targeted dependency update
will refresh Burrito and any transitive dependencies required by its published
package while avoiding unrelated dependency upgrades.

`mise.toml` will pin Zig 0.16.0 without the old Burrito-workaround comment.
The mise lockfile will be regenerated using the repository's normal mise
workflow so every supported host entry points to Zig 0.16.0 artifacts.

The existing XZ and 7zip build dependencies remain unchanged.

### Build behavior and workaround removal

The `build` task will continue detecting Darwin or Linux and setting
`ECS_TASK_DEF_RELEASE_OS` so each host builds its two CPU targets. The Darwin
branch will no longer prepend `$PWD/bin` to `PATH`.

`bin/xcrun` will be deleted. No replacement fallback will be introduced:
retaining a fallback could conceal whether Zig 0.16.0 actually builds against
the macOS 26 SDK and would preserve the debt this cutover is intended to
remove.

Burrito 1.6.0 still converts the complete `BURRITO_TARGET` value with
`String.to_existing_atom/1`, so the project-specific
`ECS_TASK_DEF_RELEASE_OS` selector remains necessary for building both CPU
targets in one release invocation. Its comment will be made version-neutral
instead of implying the behavior was checked only on Burrito 1.5.

### CI, release, and documentation

Both the CI test matrix and release binary matrix will use `macos-26`.
Linux jobs remain on `ubuntu-latest`. The release workflow's old explanation
for the macOS 15 pin will be removed.

The README will describe the shared build task without mentioning the deleted
SDK shim. Other active inline comments will be updated only where the new
versions make them stale.

## Verification

Verification will proceed from fast checks to the full release path:

1. install the updated mise toolchain and confirm Zig reports 0.16.0;
2. fetch the targeted Hex dependency update and confirm Burrito resolves to
   1.6.0;
3. run compilation with warnings as errors and the complete Mix test suite;
4. run the schema regeneration drift check;
5. search active files, excluding historical plans/specs, to ensure no
   references to Zig 0.15.2, Burrito 1.5, `macos-15`, or `bin/xcrun` remain;
6. run `mise run build` on the macOS 26 development host and require both
   macOS aarch64 and x86_64 executables; and
7. run the native Burrito release smoke test.

The full local build is the decisive regression test: it proves the new
Burrito/Zig pair links directly against the macOS 26 SDK without the deleted
shim. GitHub Actions will provide the same macOS 26 coverage after the branch
is published.

## Failure handling

If dependency or lock regeneration selects versions outside this scope, those
changes will be reverted and the update rerun with a narrower command. If the
macOS 26 build fails, the shim will not be silently restored; the failure will
be diagnosed against Burrito 1.6.0 and Zig 0.16.0, and the cutover will remain
incomplete until the direct build works or a new design is approved.

