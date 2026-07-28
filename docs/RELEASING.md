# Releasing turso.zig

Releases are tied to an exact Turso SDK Kit tag. A release is ready only after
the wrapper, the C headers, the native libraries, and clean downstream
consumers have passed the target-native CI matrix.

## Pinned release inputs

| Item | Value |
| --- | --- |
| turso.zig development version | `0.2.0` |
| Zig | `0.16.0` |
| Rust | `1.88` |
| Musl package environment | Alpine `3.22`, musl `1.2.5`, image index `sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce` |
| Turso crate | `0.7.1` |
| Turso tag | `v0.7.1` |
| Annotated tag object | `31cdceeb07d3b294e5b2f13b03cfdbbf59769b78` |
| Peeled source commit | `4a88feb7caef869c16f6215b6dc51eafd5b3e54e` |
| Zig package hash | `N-V-__8AABYTqgLLoRwhKj-QpEwCZuEqg0n62mHiVJuZRQcd` |
| `turso.h` body SHA-256 | `14ee49b4f6c00e3f8c3c710b4df1c316ecc0802e1d8b19815d8caab09f2b70cb` |
| `turso_sync.h` body SHA-256 | `38b9dc73fc2fe45c3d86d69ff2ad48b8c99d693a4462514ea50fb876aba6ee35` |
| Reproducible source epoch | `1784727869` |

Version 0.2.0 is currently unreleased. The latest tag is `v0.1.0`; this table
describes inputs being prepared for a future release, not an existing tag or
set of downloadable assets.

The tag object and peeled commit are intentionally recorded separately. The
vendored headers carry wrapper attribution above the upstream include guards,
so compare their upstream bodies with:

```sh
sed -n '/^#ifndef TURSO_H/,$p' include/turso.h | sha256sum
sed -n '/^#ifndef TURSO_SYNC_H/,$p' include/turso_sync.h | sha256sum
```

See [UPDATING_TURSO.md](UPDATING_TURSO.md) for the compatibility review
required when any pinned value changes.

## Preflight

Start from a clean checkout and confirm that `build.zig.zon`,
`src/version.zig`, `NOTICE`, the vendored headers, and the table above describe
the same release. Then run:

```sh
zig fmt --check .
bash -n tools/*.sh tests/release-package*.sh
shellcheck tools/*.sh tests/release-package*.sh
zig build test
zig build examples
zig build docs
zig build test-sync-abi -Dsync=true
tools/check-abi-symbols.sh --header-only
tools/check-abi-symbols.sh --sync --header-only
```

On Linux, also run the focused ownership, resource, and fault gates:

```sh
tools/check-valgrind.sh -Dnative=source -Dlinkage=static -j2
zig build test-soak -Dnative=source -Doptimize=ReleaseSafe
zig build test-disk-fault
```

The credential-free sync integration gate requires a locally built `tursodb`
from the pinned Turso source:

```sh
zig build test-sync-e2e \
  -Dsync=true \
  -Dsync-server=/path/to/tursodb \
  -Doptimize=ReleaseSafe
```

This starts an isolated loopback server and verifies create, push, bootstrap,
pull, apply, query, statistics, and checkpoint behavior with two clients.

## Required hosted checks

Every job in `.github/workflows/ci.yml` must pass for the release commit:

- native Debug and ReleaseSafe tests on Linux, macOS, and Windows;
- x86_64 and aarch64 execution on Linux glibc, Linux musl, and macOS, plus
  x86_64 on Windows;
- source and system native-library modes;
- static and dynamic linkage;
- base and sync ABI manifests;
- clean downstream consumers;
- deterministic source and target-native package assembly;
- extracted-package smoke tests and dynamic dependency inspection; and
- the local-server sync round trip.

The scheduled extended workflow records a deterministic lifecycle/fan-out soak.
The drift workflow is advisory: it tests the wrapper against current Turso main
and Zig master without changing release provenance.

Targets absent from this matrix—including Android and iOS—are not release
claims. Source-mode cross compilation is likewise not a support claim unless a
complete target linker, sysroot, and native runtime proof are supplied. Musl
assets are built and consumer-smoked target-natively in the pinned Alpine
environment; dynamic archives require musl libc and `libgcc_s`.
Windows ARM64 package policy exists in the tooling, but the hosted lane is
disabled pending [issue #4](https://github.com/tzekid/turso.zig/issues/4), so
Windows ARM64 assets are not part of the current release.

## ABI and package review

`tests/expected-base-symbols.txt` and `tests/expected-sync-symbols.txt` are exact
allowlists. A missing export or an unexpected new export fails the build. Symbol
lists are necessary but not sufficient: `zig build test-abi` and
`zig build test-sync-abi -Dsync=true` also compile C probes and compare public
layouts, constants, and signatures.

Release packages are assembled only by `tools/package-release.sh`. A base native
package contains the Zig source, `turso.h`, one target's `turso_sdk_kit`
library, wrapper and upstream notices, a provenance manifest, and checksums. A
sync package substitutes `turso_sync_sdk_kit`, adds `turso_sync.h`, and records
both symbol surfaces. Do not link both Rust SDK Kit libraries into one sync
consumer.

`tests/release-package.sh` is the integration wrapper. On Linux it can build
two byte-identical source archives, assemble static and dynamic native archives,
and run consumers from clean extractions:

```sh
tests/release-package.sh \
  --upstream-root /path/to/exact-v0.7.1-checkout \
  --static /path/to/libturso_sdk_kit.a \
  --dynamic /path/to/libturso_sdk_kit.so \
  --static-deps /path/to/native-static-libs.txt \
  --dynamic-deps /path/to/native-dynamic-deps.txt \
  --target x86_64-unknown-linux-gnu \
  --cpu-baseline x86-64-v1 \
  --minimum-platform 'ubuntu-24.04 glibc>=2.35' \
  --ci-run-url https://github.com/OWNER/REPO/actions/runs/RUN_ID
```

Pass `--sync` for the sync variant. The CI workflow is the reference for
collecting `native-static-libs`, dynamic dependencies, minimum-platform
metadata, and platform-specific library names.

### Choosing an asset

There is no automatic downloader or platform selector. Building from the
source archive is the canonical fallback.

| Choice | Filename pattern |
| --- | --- |
| Base source | `turso-zig-<version>-source.tar.gz` |
| Sync source | `turso-zig-<version>-source-sync.tar.gz` |
| Base native | `turso-zig-<version>-<target>-<static\|dynamic>-encryption-pure-rust-crypto.tar.gz` |
| Sync native | `turso-zig-<version>-<target>-<static\|dynamic>-sync-pure-rust-crypto.tar.gz` |

Select the exact target triple, base or sync ABI, and linkage needed by the
consumer. Each native archive contains the Zig source, the matching header set,
one selected SDK Kit runtime/static library, a Windows import library when
needed, both projects' notices, `manifest.json`, and `checksums.sha256`.

The release collector requires exactly 30 archives and 30 checksum
sidecars: two source variants plus base/sync static/dynamic archives for seven
target-native platforms.

## Publication

1. Update `CHANGELOG.md` and verify the package version in
   `build.zig.zon` and `src/version.zig`.
2. Merge the release commit and require a green CI run on the default branch.
3. Create an annotated `v<version>` tag pointing at that exact commit.
4. Push the tag. Tag CI repeats the complete validation and creates the GitHub
   Release from the package artifacts only after every required job passes.
5. Download the public assets, verify their checksum sidecars, and run
   `tools/smoke-release.sh --archive <archive>` from a clean directory.

Do not publish if provenance disagrees, a platform job is skipped, a native
artifact embeds a checkout or cache path, required notices are missing, or a
claimed target was not executed natively. Do not claim credentialed Turso Cloud
coverage from the local-server suite; that remains an application-level canary.
