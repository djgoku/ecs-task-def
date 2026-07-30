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
`ecs-task-def@0.1.2`. A version filter excludes the exact
`ecs-task-def@0.1.0` tag, whose default scaffold points at the obsolete Pkl
package repository; `0.1.1` is the first supported release.

The release binary is a raw asset named
`ecs-task-def-{{.OS}}_{{.Arch}}`. Registry replacements map Aqua's platform
names to the repository's release naming:

- `darwin` to `macos`
- `amd64` to `x86_64`
- `arm64` to `aarch64`

The supported environments are macOS and Linux on ARM64 and x86-64. The
installed executable is exposed as `ecs-task-def`.

The concrete registry entry is:

```yaml
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

The checksum declaration points at each binary's matching
`ecs-task-def-<os>_<arch>.sha256` release asset. Native Aqua can use that
sidecar, and it remains a fallback for mise when GitHub does not supply an
asset digest. Mise 2026.7.0 normally verifies the GitHub API's per-asset digest
instead of downloading the sidecar when that digest is available.

Apart from the exact broken-tag exclusion, the registry remains
version-agnostic, so the same entry works for future releases that preserve the
established tag and asset naming contract.

## Local Interface

The registry is opt-in. From the repository root, it is supplied to mise
explicitly:

```sh
MISE_AQUA_REGISTRIES="file://$PWD/registry.yaml" \
  mise x aqua:djgoku/ecs-task-def@0.1.2 -- ecs-task-def --help
```

`$PWD` is absolute in this context, producing the required absolute `file://`
registry URL. The registry file includes this example as a short header
comment. Neither `mise.toml` nor `mise.lock` is changed by this feature.

## Verification

Verification will:

1. validate `registry.yaml` against Aqua's published registry JSON schema and
   load it with mise's Aqua registry parser;
2. record the existing `mise.toml` and `mise.lock` diffs;
3. run from a disposable directory with isolated `MISE_DATA_DIR`,
   `MISE_CACHE_DIR`, `XDG_STATE_HOME`, and an empty
   `MISE_GLOBAL_CONFIG_FILE`, so project and global tool configuration cannot
   affect the result;
4. use the absolute `file://` registry URL with mise to discover stripped
   versions, confirming that `0.1.1` and `0.1.2` are present and `0.1.0` is
   excluded;
5. install exact version `0.1.2` through the Aqua backend on the current host;
6. confirm verbose mise output reports GitHub API digest verification;
7. download the matching binary and `.sha256` release assets separately in the
   disposable directory and confirm the sidecar validates the binary;
8. execute the installed `ecs-task-def` help command successfully; and
9. compare the recorded repository diffs to prove `mise.toml` and `mise.lock`
   were not modified.

Add an offline regression test to `test/release_tasks_test.exs` that keeps the
registry's asset template, platform replacements, installed command name,
exact broken-tag filter, and checksum sidecar template aligned with the release
asset naming contract. Testing must not add the project package to `mise.toml`
or modify the existing `mise.lock`.

## Scope

This change adds `registry.yaml` and the focused offline regression test, plus
disposable verification needed to prove the registry works. It does not add an
`aqua.yaml`, register the package in Aqua's standard registry, wire the local
registry into normal project activation, or alter release asset production.

The registry excludes the broken `0.1.0` without deleting it. Whether to retain
or delete that release's assets remains a separate follow-up decision. This
design does not authorize deleting or otherwise modifying release assets.

## Alternatives Considered

A current-version-only entry with fixed URLs and checksums would be simple but
would become stale on every release. Adding an `aqua.yaml` package configuration
would support direct Aqua CLI installation but is unnecessary for the requested
mise workflow. A single templated registry entry is the smallest durable
solution.
