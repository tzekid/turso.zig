# Repository automation guidance

This repository deliberately uses exact development snapshots on `master`.
Read `tools/development-targets.json` and
`docs/DEVELOPMENT_CHANNELS.md` before changing Zig or Turso inputs.

## Hard boundaries

- Keep the binding package version at its current value unless the user
  explicitly asks for a release-version change.
- Update Zig and Turso in separate maintenance pull requests. Never combine
  both moving-channel candidates in one automated change.
- Never modify, force-push, or merge into a `v*-stable` branch during nightly
  maintenance.
- Never move an existing release tag.
- Never weaken runtime-version matching, ABI allowlists, ownership checks, or
  release guards to make a candidate pass.
- Stop and report uncertainty about ABI layout, ownership, destructors,
  callbacks, error lifetimes, licenses, or platform behavior. Such changes
  require human review.
- Codex-generated source fixes stay in a draft pull request.

## Required verification

Use the exact Zig version from `tools/development-targets.json`.

```sh
tools/check-development-targets.sh
tests/classify-development-targets.sh
zig fmt --check build.zig src tests examples bench tools/*.zig
zig build test-pure
zig build test-ownership-invariants -Doptimize=ReleaseFast
zig build test -j2 --summary all
zig build examples
zig build docs
zig build test-abi
zig build test-sync-abi -Dsync=true -j2 --summary all
tools/check-abi-symbols.sh --header-only
tools/check-abi-symbols.sh --sync --header-only
```

Run the dynamic/system, feature, Valgrind, disk-fault, soak, consumer, and
local-sync-server gates when the build graph, native boundary, or Turso
behavior changes. Platform support is limited to the target-native evidence in
`docs/PLATFORMS.md`; a cross-compile does not create a support claim.

Stable publication must first move both upstreams to stable versions with real
tag provenance. `tools/check-release-inputs.sh` must pass before any package or
tag is produced.
