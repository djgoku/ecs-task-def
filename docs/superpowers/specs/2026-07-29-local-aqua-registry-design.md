# Local Aqua Registry

## Goal

Add a repository-local Aqua registry that lets maintainers test installation of
released `ecs-task-def` binaries through mise without changing the repository's
normal tool configuration.

## Registry Design

Add a root-level `registry.yaml` containing one `github_release` package named
`djgoku/ecs-task-def`.

The package uses `ecs-task-def@` as its release-tag version prefix. Mise callers
therefore select ordinary versions such as `0.1.2` or `latest`, while Aqua
resolves the corresponding GitHub release tag such as
`ecs-task-def@0.1.2`.

The release binary is a raw asset named
`ecs-task-def-{{.OS}}_{{.Arch}}`. Registry replacements map Aqua's platform
names to the repository's release naming:

- `darwin` to `macos`
- `amd64` to `x86_64`
- `arm64` to `aarch64`

The supported environments are macOS and Linux on ARM64 and x86-64. The
installed executable is exposed as `ecs-task-def`.

Each binary is verified with its matching
`ecs-task-def-<os>_<arch>.sha256` GitHub release asset. The registry remains
version-agnostic so the same entry works for current and future releases that
preserve the established tag and asset naming contract.

## Local Interface

The registry is opt-in. It is supplied to mise explicitly:

```sh
MISE_AQUA_REGISTRIES="file://$PWD/registry.yaml" \
  mise x aqua:djgoku/ecs-task-def@0.1.2 -- ecs-task-def --help
```

The registry file includes this example as a short header comment. Neither
`mise.toml` nor `mise.lock` is changed by this feature.

## Verification

Verification will:

1. validate `registry.yaml` against Aqua's registry schema or an equivalent
   Aqua/mise parser;
2. use the absolute `file://` registry URL with mise to discover released
   versions;
3. install `0.1.2` through the Aqua backend on the current host;
4. confirm checksum verification uses the matching release sidecar; and
5. execute the installed `ecs-task-def` help or version command successfully.

Testing must not add the project package to `mise.toml` or modify the existing
`mise.lock`.

## Scope

This change adds only `registry.yaml` plus its development documentation and
tests or disposable verification needed to prove the registry works. It does
not register the package in Aqua's standard registry, wire the local registry
into normal project activation, or alter release asset production.

Whether to retain or delete assets from the broken `0.1.0` release is a
separate follow-up decision. That investigation will first determine how the
release is referenced and whether deleting assets would make existing installs
less diagnosable. This design does not authorize deleting release assets.

## Alternatives Considered

A current-version-only entry with fixed URLs and checksums would be simple but
would become stale on every release. Adding an `aqua.yaml` package configuration
would support direct Aqua CLI installation but is unnecessary for the requested
mise workflow. A single templated registry entry is the smallest durable
solution.
