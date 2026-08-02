# Releasing turso.zig

Releases are tied to an exact Turso SDK Kit tag. A release is ready only after
the wrapper, the C headers, the native libraries, and clean downstream
consumers have passed the target-native CI matrix.

## Current development inputs are not releasable

| Item | Value |
| --- | --- |
| turso.zig version | `0.1.1` |
| Zig development snapshot | `0.17.0-dev.1509+bb296ab9b` |
| Rust | `1.88` |
| Turso development version | `0.8.0-pre.2` |
| Turso channel | `main` |
| Turso commit | `e99973a43e906325f46f27e6bd3fa404dd5dd31b` |
| Zig package hash | `N-V-__8AAENi3wKTg86MeIZppqc3LdC7BjR6h5ZfImor8FOk` |
| `turso.h` body SHA-256 | `14ee49b4f6c00e3f8c3c710b4df1c316ecc0802e1d8b19815d8caab09f2b70cb` |
| `turso_sync.h` body SHA-256 | `f9de9cb7eab356e59fd7efdbc02c6a35598588202297535436ecfeaa8ad7bda1` |
| Reproducible source epoch | `1785563505` |

These are the reproducible development inputs on `master`, not release
candidates. `tools/check-release-inputs.sh` rejects the `-dev` Zig compiler,
the `-pre` Turso version, null tag provenance, and the `master` branch.
Preparing a stable release is a separate change that selects stable Zig and
Turso versions, records a real annotated Turso tag, and deliberately decides
the binding version. The `v0.1.1-stable` branch remains the locked stable
baseline.

For a future stable release, the tag object and peeled commit are recorded
separately. Vendored headers carry wrapper attribution above the upstream
include guards, so compare their upstream bodies with:

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

The release workflow reuses `.github/workflows/ci.yml`, so the following
target-native gates must pass for the tagged commit:

- Linux x64 glibc, macOS ARM64, and Windows x64 MSVC Tier 1 lanes;
- the Linux ARM64 glibc Tier 2 lane;
- the canonical Linux functional suite;
- default source/static linkage and clean source/system consumers;
- base and sync ABI manifests; and
- documentation, examples, ownership invariants, and provenance checks.

Before creating the tag, manually dispatch the extended workflow for the
release commit. It owns dynamic/system linkage, feature variants, Valgrind,
fault injection, the deterministic lifecycle/fan-out soak, and the local-server
sync round trip. The drift workflow remains advisory.

The tagged release assembles only two platform-independent source packages:
base and sync. It assembles each package twice, requires byte-identical output,
smokes a clean extraction, and publishes it with a checksum sidecar. Native
package tooling remains available for explicit experiments, but this project
does not currently publish prebuilt native binaries.

macOS Intel and Linux musl are out of scope. Windows ARM64 remains a Tier 3
scheduled experiment pending [issue #4](https://github.com/tzekid/turso.zig/issues/4)
and is not a release claim. Android, iOS, and browser/WASM are likewise absent
from the release contract.

## ABI and package review

`tests/expected-base-symbols.txt` and `tests/expected-sync-symbols.txt` are exact
allowlists. A missing export or an unexpected new export fails the build. Symbol
lists are necessary but not sufficient: `zig build test-abi` and
`zig build test-sync-abi -Dsync=true` also compile C probes and compare public
layouts, constants, and signatures.

Release packages are assembled only by `tools/package-release.sh`. The base
source package contains the Zig source, `turso.h`, wrapper and upstream notices,
a provenance manifest, and checksums. The sync source package additionally
contains `turso_sync.h`, `src/sync.zig`, and the sync symbol manifest.

`tests/release-package.sh` remains the integration wrapper for manually
rehearsing a future native package. On Linux it can build two byte-identical
source archives, assemble static and dynamic native archives, and run consumers
from clean extractions:

```sh
tests/release-package.sh \
  --upstream-root /path/to/exact-stable-tag-checkout \
  --static /path/to/libturso_sdk_kit.a \
  --dynamic /path/to/libturso_sdk_kit.so \
  --static-deps /path/to/native-static-libs.txt \
  --dynamic-deps /path/to/native-dynamic-deps.txt \
  --target x86_64-unknown-linux-gnu \
  --cpu-baseline x86-64-v1 \
  --minimum-platform 'ubuntu-24.04 glibc>=2.35' \
  --ci-run-url https://github.com/OWNER/REPO/actions/runs/RUN_ID
```

Pass `--sync` for the sync variant. Native packages produced this way are not
release assets under the current support contract.

### Choosing an asset

There is no automatic downloader or platform selector. Building from the
source archive is the canonical fallback.

| Choice | Filename pattern |
| --- | --- |
| Base source | `turso-zig-<version>-source.tar.gz` |
| Sync source | `turso-zig-<version>-source-sync.tar.gz` |

Each archive contains the appropriate Zig source and headers, both projects'
notices, `manifest.json`, and `checksums.sha256`. Consumers build the pinned
native SDK Kit for their supported target during the normal Zig build.

## Publication

1. Update `CHANGELOG.md` and verify the package version in
   `build.zig.zon` and `src/version.zig`.
2. Merge the release commit, require a green supported-platform run, and
   manually run the extended workflow for that exact commit.
3. Create an annotated `v<version>` tag pointing at that exact commit.
4. Push the tag. The release workflow repeats the supported-platform validation
   and creates the GitHub Release from the two verified source packages only
   after every required job passes.
5. Download the public assets, verify their checksum sidecars, and run
   `tools/smoke-release.sh --archive <archive>` from a clean directory.

Do not publish if provenance disagrees, an applicable supported-platform job is
skipped, an archive embeds a checkout or cache path, required notices are
missing, or a claimed target was not executed natively. Do not claim
credentialed Turso Cloud coverage from the local-server suite; that remains an
application-level canary.
