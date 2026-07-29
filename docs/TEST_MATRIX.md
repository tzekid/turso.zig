# Test matrix

The test graph is organized around the risks of a pre-1.0 native ABI:
declaration drift, ownership, failure cleanup, platform linkage, durability,
and clean downstream consumption.

## Local gates

| Gate | Command | What it establishes |
| --- | --- | --- |
| Formatting | `zig fmt --check .` | Zig source is canonical |
| Pure Zig | `zig build test-pure` | Status, diagnostics, values, config, C-string, and statement-I/O logic |
| Ownership invariants | `zig build test-ownership-invariants -Doptimize=ReleaseFast` | Owner counts and active-handle identity still panic when safety assertions are disabled |
| Raw ABI | `zig build test-abi` | Header layout/signatures, status values, runtime version, native `SELECT 1`, error ownership |
| Safe API | `zig build test-safe` | Database, statements, rows, decode, transactions, callbacks, failures, SQL corpus |
| Structured batches | `zig build test-batches` | Parameters, partial reports, bounded ownership, transaction modes, allocator and rollback failure |
| Aggregate | `zig build test` | All of the above plus durability, 32-bit compile safety, and short soak |
| Examples | `zig build examples` | Public local examples compile and run; secret-bearing examples compile only |
| API docs | `zig build docs` | Both public module surfaces are documentation-clean |
| Sync workflows | `zig build test-sync-workflows -Dsync=true` | Deterministic C-fixture-backed typed runners, push/pull/apply summaries, error cleanup, and retained-I/O recovery |
| Sync ABI | `zig build test-sync-abi -Dsync=true` | Real pinned sync SDK ABI probes and smokes plus deterministic transport/lifecycle fixtures |
| Sync E2E | `zig build test-sync-e2e -Dsync=true -Dsync-server=/path/to/tursodb` | Real local `tursodb` two-client push, bootstrap, pull/apply, stats, and checkpoint |
| ABI exports | `zig build test-abi-symbols` | Native exports exactly match the selected header manifest |
| Disk faults | `zig build test-disk-fault` | Linux ENOSPC and short-write/EIO handling |
| Valgrind | `tools/check-valgrind.sh` | Representative owners have no definite/indirect leaks |
| Extended soak | `zig build soak -Doptimize=ReleaseSafe -- ITERATIONS WORKERS SEED` | Repeated lifecycle and contention with bounded FD/thread growth |

Run Debug and ReleaseSafe for changes that affect native state. Build both
static and dynamic linkage when changing the build graph, package layout, or
FFI boundary.

## Hosted target matrix

The blocking CI workflow runs a default source/static configuration
target-natively rather than treating a cross compile as execution evidence.
Functional behavior is exercised comprehensively once on Linux x64; the other
lanes focus on platform linkage, ABI exports, and clean consumers.

| Tier | Platform | Required ordinary-CI evidence |
| --- | --- | --- |
| 1 | Linux glibc x86_64 | Debug aggregate, examples, exact ABI, source/system consumers |
| 1 | macOS ARM64 | ReleaseSafe aggregate, exact ABI, source/system consumers |
| 1 | Windows x86_64 MSVC | ReleaseSafe aggregate, exact ABI, source/system consumers |
| 2 | Linux glibc ARM64 | ReleaseSafe aggregate, exact ABI, source consumer |

Windows jobs select the explicit Zig MSVC target that matches Cargo's native
Rust triple. This prevents a GNU Zig executable from being linked to an MSVC
static archive.

The scheduled extended workflow, rather than ordinary CI, owns:

- source and system dynamic linkage on the supported operating systems;
- Linux feature variants;
- Valgrind and deterministic disk-fault injection;
- long lifecycle and contention soaks; and
- static/dynamic sync ABI plus the local-server sync round trip.

This keeps expensive orthogonal combinations without multiplying them across
every platform and every change.

### Workflow ownership and budgets

| Workflow | Trigger | Responsibility | Budget |
| --- | --- | --- | --- |
| `ci.yml` | Pull requests, pushes to `master`, manual/reusable call | Quick checks plus Tier 1/Tier 2 source/static compatibility | 10–20 minutes elapsed; no routine artifacts |
| `extended.yml` | Weekly or manual | Dynamic/system linkage, features, faults, Valgrind, sync E2E, long soak | Bounded per job; seven-day diagnostics |
| `windows-arm-preview.yml` | Weekly or manual | Tier 3 native ARM64 static promotion probe | 45-minute job cap; 10–15-minute stages |
| `release.yml` | Version tags or manual rehearsal | Reuse supported CI, certify two source archives, publish tags | Release-only artifacts, seven-day workflow retention |
| `drift.yml` | Weekly or manual | Advisory current-Turso and Zig-master compatibility | Seven-day diagnostics |

Documentation-only changes still run the quick gate but skip native platform
jobs. `Supported platforms` is the stable aggregate check to use for branch
protection; it accepts intentionally skipped path-filtered jobs but fails if an
applicable lane fails.

The cleanup baseline was a 27-job run consuming approximately 466
runner-minutes and 50 minutes elapsed, with about 245 runner-minutes spent on
packages. Ordinary code changes should remain near 25–45 runner-minutes and
10–20 minutes elapsed. A sustained regression above those bounds should be
investigated before adding concurrency or restoring a matrix axis.

Targets outside the blocking matrix are explicit non-claims:

| Target | Current status | Evidence required before promotion |
| --- | --- | --- |
| Windows ARM64 | Tier 3 experimental | Ten consecutive native static probe passes, then staged dynamic/system/sync promotion |
| macOS Intel | unsupported | Out of project scope |
| Linux musl | unsupported | Out of project scope |
| Android | unclaimed | Package the SDK Kit for a declared API level and run persistence/sync on device or emulator |
| iOS | unclaimed | Package a device/simulator framework with a deployment/signing contract and execute both environments |
| browser/WASM | unsupported | Supply the missing WASM driver, worker/OPFS host integration, and real-browser tests |

The safe and raw Zig modules compile as documentation objects for
`aarch64-linux-android` and `aarch64-ios` in system mode. That compile-only
check protects API portability; it does not promote either platform. See
[Platform boundaries](PLATFORMS.md) for the architectural and packaging
requirements.

Release jobs assemble the base and sync source archives twice, compare them
byte-for-byte, reject dirty inputs and bad checksums, and build a consumer from
the extracted archive. Native package tooling remains available for deliberate
future work, but CI does not build or publish prebuilt native libraries.
Every workflow action is pinned to an exact commit.

## Test layers

### ABI and version

- C probes compare size, alignment, offsets, enum values, and function types.
- Expected base and sync symbol lists are exact allowlists.
- Safe calls reject a native library whose `turso_version()` does not match the
  version selected by the build.
- `-Dturso-source=/path` builds and tests an explicit Turso checkout while
  deriving that checkout's workspace version.
- The weekly drift workflow compares both headers and generated declarations,
  inspects symbols/link dependencies, and runs the base and sync safe suites
  against current Turso main without changing the production pin.

### Ownership and failure

Tests cover partial construction, allocator failure, native error strings,
idempotent cleanup on one owner variable, parent/child teardown, stale row
borrows, reusable prepared-query leases, multiple idle statements with one
active execution, reset failure, structured-batch partial progress and bounded
materialization, transaction and rollback-failure poisoning, callback context
and aggregate-state destruction, and sync transfer/consume rules. Subprocess
probes verify that owner-count and active-handle invariant violations remain
fatal in Debug and ReleaseFast. Pure config tests pin every v0.7.1 feature token
and its order, reject duplicate/known or malformed unchecked names, and
exercise feature-render allocation failure.

The safe wrapper never races a handle in ways forbidden by the C header. One
`Database` may fan out independent connections. A Connection may retain
multiple idle statements but admits only one active execution; each individual
statement and sync operation remains exclusive.

### Durability and production behavior

The aggregate includes persisted reopen, WAL recovery across process exit,
committed versus uncommitted state, busy timing, writer contention, read-only
paths, database-full and busy-snapshot recovery, memory/syscall/native VFS
selection, large values, and a differential SQL subset against SQLite
semantics.

The platform-native VFS test skips only when the native SDK reports that the
runner kernel cannot initialize the requested backend, or for the exact
`io_uring_cqe: invalid input parameter` existing-file rejection produced by
the pinned SDK Kit on Linux aarch64 hosted runners. The syscall persistence
suite remains blocking on that runner, and all other native-VFS failures remain
blocking.

### Sync

Deterministic C fixtures cover operation polling, result extraction, changes
consumption, I/O item completion/poisoning, authorization redaction, HTTP
status bounds, atomic full writes, missing reads, and lexical path rejection.
They also cover the high-level no-change and apply paths, push-before-pull
ordering, wait/apply/push failure cleanup, and caller-owned recovery through
`runVoid`. Transport tests prove static authorization compatibility,
per-HTTP-item token rotation, provider-null native-header preservation,
fixed-category provider failure cleanup, invalid-header rejection, exact
case-insensitive replacement, and unhandled redirects against a loopback
server.
Native-independent sync configuration tests exercise the partial-bootstrap
platform policy for Linux, macOS, Windows, and FreeBSD: file-backed partial
bootstrap is Linux-only while `:memory:` remains portable. This proves wrapper
rejection deterministically without treating a cross-compiled binary as
target-native runtime evidence.

The loopback E2E gate starts the pinned `tursodb --sync-server`, creates two
independent local clients through `runVoid`/`runConnection`, exercises the
public push-then-pull `sync` helper, bootstraps and pushes from the second
client, applies its changes through `pull`, verifies local SQL state, reads
statistics through the low-level typed driver, and checkpoints. This is real
SDK/server coverage without Cloud credentials; deterministic C fixtures remain
responsible for adversarial cleanup states and rotating authorization.

## Release acceptance

A tagged release requires:

1. a clean tree and consistent package/upstream provenance;
2. the reusable supported-platform workflow in `.github/workflows/ci.yml`;
3. a successful manually dispatched extended soak for the release commit;
4. deterministic base and sync source archives and clean extracted consumers;
5. exact ABI symbol checks on every supported native lane;
6. generated API docs and public examples;
7. downloaded-release checksum and consumer verification.

Normal CI deliberately does not require Cloud credentials. A live Cloud canary
may be run as additional private evidence, but local protocol E2E and the
documented feature limits remain the public claims.

Unsupported claims include source-mode cross compilation without an explicitly
configured Cargo linker/sysroot, platforms absent from the target matrix,
Windows ARM64 release support while issue #4 remains experimental, macOS Intel,
Linux musl, Android/iOS application support, browser/WASM, caller-driven local
async opening, query interruption, sync cancellation, remote cipher selection,
and transform callbacks.
