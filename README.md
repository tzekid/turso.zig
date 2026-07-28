# turso.zig

[![CI](https://github.com/tzekid/turso.zig/actions/workflows/ci.yml/badge.svg)](https://github.com/tzekid/turso.zig/actions/workflows/ci.yml)
[![Zig 0.16.0](https://img.shields.io/badge/Zig-0.16.0-f7a41d)](https://ziglang.org/download/)
[![MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Community-maintained Zig bindings for the [Turso](https://github.com/tursodatabase/turso)
embedded database. The package binds Turso's supported SDK Kit C ABI and layers
an ownership-safe, Zig-native API over the exact raw interface.

This repository is the implementation proposed in
[tursodatabase/turso#3357](https://github.com/tursodatabase/turso/issues/3357).
It is not currently an official Turso SDK.

~~~zig
const std = @import("std");
const turso = @import("turso");

pub fn main() !void {
    var database = try turso.Database.open(
        std.heap.page_allocator,
        .{ .path = ":memory:" },
    );
    defer database.deinit();

    var connection = try database.connect(.{});
    defer connection.deinit();

    _ = try connection.exec(
        "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
        &.{},
        .{},
    );
    _ = try connection.execParams(
        "INSERT INTO users VALUES (?1, ?2)",
        .{ 1, "Ada" },
        .{},
    );

    var rows = try connection.query("SELECT id, name FROM users", &.{}, .{});
    defer rows.deinit();
    while (try rows.next()) |row| {
        std.debug.print("{d}: {s}\n", .{
            try row.get(i64, 0),
            try row.get([]const u8, 1),
        });
    }
}
~~~

## What is implemented

| Area | Support |
| --- | --- |
| Database access | Memory and file databases, source or system SDK Kit, static or dynamic linkage |
| Queries | Reusable prepared and one-shot statements, positional/named parameters, structured batches, typed row decoding |
| Values | Null, integer, real, UTF-8 text, arbitrary blobs, borrowed and owned representations |
| Transactions | Deferred, immediate, exclusive, and concurrent modes with explicit commit/rollback |
| Extensions | Managed scalar/aggregate functions, collations, and opt-in extension loading |
| Operations | Busy timeouts, autocommit state, last insert row ID, metadata, diagnostics |
| Storage | Default, memory, syscall, Linux io_uring, and experimental Windows IOCP VFS selection |
| Security | Local AES-GCM/AEGIS encryption, key redaction, extension loading disabled by default |
| Cloud sync | Opt-in SDK Kit, caller-owned HTTP/filesystem transport, push, pull/apply, stats, checkpoint |
| Raw ABI | Complete pinned `turso.h` and `turso_sync.h` declarations under `raw` |

`FeatureSet` has a typed field for every experimental token parsed by SDK Kit
v0.7.1, including `mvcc_passive_checkpoint`, and renders them in canonical
order. `unchecked_extra` is an intentionally conspicuous escape hatch for
unique, valid UTF-8 tokens not yet known to this binding. Upstream may silently
ignore those names; accepting their syntax is not a support promise.

The release matrix runs natively on Linux glibc, Linux musl, and macOS for
x86_64 and aarch64, and on Windows for x86_64. Musl packages execute inside a
pinned architecture-matching Alpine 3.22 environment rather than under
emulation. Windows ARM64 remains outside the current release claim while its
hosted lane is isolated in
[issue #4](https://github.com/tzekid/turso.zig/issues/4). Linux additionally
runs fault injection, Valgrind ownership smokes, deterministic soak tests,
package extraction tests, and a real two-client sync round trip through a local
`tursodb` server.

## Install

The source backend requires Zig 0.16.0, Rust/Cargo 1.88, and a C toolchain.
Add the tagged package:

```sh
zig fetch --save=turso git+https://github.com/tzekid/turso.zig#v0.2.0
```

Then expose its module from your `build.zig`:

```zig
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});
const dependency = b.dependency("turso", .{
    .target = target,
    .optimize = optimize,
});

const executable = b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "turso", .module = dependency.module("turso") },
        },
    }),
});
```

Windows source builds use Rust's MSVC SDK Kit artifact. Select the matching
target in the application build (`-Dtarget=x86_64-windows-msvc` or
`-Dtarget=aarch64-windows-msvc`) so Zig and Rust use one ABI; the resolved
target forwarded above keeps the dependency and application aligned.

The dependency builds Turso v0.7.1 from source by default. To use a separately
installed SDK Kit, forward `.native = "system"` and
`.@"native-path" = "/your/prefix"`; the library is read from `prefix/lib`.
Dynamic Unix builds add that directory as a runtime search path. A Windows
dynamic package links through `prefix/lib/turso_sdk_kit.dll.lib`; add
`prefix/bin` to `PATH` when running the application.

Supported dependency options are:

| Option | Default | Purpose |
| --- | --- | --- |
| `native` | `source` | `source` builds the pin; `system` links an installed SDK Kit |
| `linkage` | `static` | `static` or `dynamic` |
| `encryption` | `true` | Build local encryption support |
| `fts` | `false` | Build full-text-search support |
| `sync` | `false` | Substitute the Cloud sync SDK Kit and expose `turso_sync` |
| `turso-source` | unset | Test against an explicit Turso source checkout |
| `rust-target` | inferred | Override Cargo's target triple |
| `allow-source-cross` | `false` | Acknowledge an externally configured Cargo cross toolchain |

Source-mode cross compilation is intentionally rejected unless Cargo has an
explicit target linker/sysroot. Use a target-native system library for release
cross builds. Musl dynamic source builds automatically disable Rust's default
static CRT so the SDK Kit `cdylib` is emitted; static and dynamic builds use
separate Cargo caches.

`zig build native-artifact` installs the selected source-built SDK Kit under
`zig-out/lib` (and its runtime library under `zig-out/bin` for Windows dynamic
linkage). Static artifacts omit Rust's duplicate compiler-runtime members and
transient build-root metadata during this step; the original Cargo output
remains untouched. macOS dynamic artifacts receive relocatable `@rpath`
install names.

### Release archives

Building the pinned SDK Kit from source is the canonical fallback. Release
archives are an optional way to supply a target-native library through
`native = "system"`; the package does not download or select one automatically.

| Need | Archive name |
| --- | --- |
| Base SDK Kit, build locally | `turso-zig-<version>-source.tar.gz` |
| Sync SDK Kit, build locally | `turso-zig-<version>-source-sync.tar.gz` |
| Base, prebuilt native | `turso-zig-<version>-<target>-<static\|dynamic>-encryption-pure-rust-crypto.tar.gz` |
| Sync, prebuilt native | `turso-zig-<version>-<target>-<static\|dynamic>-sync-pure-rust-crypto.tar.gz` |

Choose the exact Rust target triple for the machine, then choose `static` or
`dynamic` and base or sync. Point `native-path` at the extracted prefix and
pass the matching `linkage` and `sync` options. Every archive has a checksum
sidecar and contains a provenance manifest, wrapper and upstream notices, the
appropriate header set, and exactly one SDK Kit variant. Current prebuilt
targets are:

| Platform | Target triples |
| --- | --- |
| Linux glibc | `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu` |
| Linux musl (Alpine 3.22, musl 1.2.5) | `x86_64-unknown-linux-musl`, `aarch64-unknown-linux-musl` |
| macOS | `x86_64-apple-darwin`, `aarch64-apple-darwin` |
| Windows | `x86_64-pc-windows-msvc` |

Support means the packaged library and a clean consumer have executed
target-natively; accepting a target triple or compiling declarations is not
enough. Android and iOS remain unclaimed, and browser/WASM is unsupported.
[Platform boundaries](docs/PLATFORMS.md) records the evidence, the distinction
between source and system mode, and the exact work required to add a platform
without overclaiming it.

## Ownership

`Database`, `Connection`, `Statement`, `Rows`, `Transaction`, sync operations,
and owned values are move-only owners by convention. Release children before
parents:

```text
Row < Rows/Statement < Transaction < Connection < Database
```

Text and blob slices returned by a `Row` borrow the current native row and
expire on the next statement operation. Use `row.toOwned` or typed owned
decoding when data must outlive iteration. Supplied `Diagnostics` values copy
native error text into a fixed buffer; native strings are released on every
path.

Prepared statements keep heap-stable state: multiple statements may remain
idle on one Connection, while exactly one execution or Rows lease is active.
`Statement.query` and `queryParams` return a temporary Rows lease; `finish`,
`cancel`, or `deinit` resets that execution so the Statement can be rebound.
The older `intoRows` path remains explicitly consuming.

## Structured batches

`Connection.executeBatch` executes a slice of `BatchItem` values with
positional, explicitly named, or no parameters. Its transaction policy is
deliberate: `.none` preserves successful earlier entries, while `.deferred`,
`.immediate`, `.exclusive`, or `.concurrent` commits all entries together and
rolls back on failure. There are no implicit retries.

Errors remain ordinary Zig errors. The caller-owned `BatchReport` records every
completed entry, the failed input index, and whether a wrapper-owned
transaction committed, rolled back, or failed to roll back. Query results are
discarded by default. Opting into `.materialize_rows` requires aggregate
`max_rows`, `max_items`, and `max_bytes` limits; returned metadata, text, blobs,
and rows remain owned by the report until its idempotent `deinit`.

`Transaction.executeBatch` uses the caller's already-active transaction and
rejects a nested batch transaction mode. The older `execBatch(sql)` remains
the lightweight parameterless SQL-script API. See
[examples/batch.zig](examples/batch.zig) for atomic, non-atomic, and bounded
materialization paths.

See [docs/API.md](docs/API.md) and [docs/CALLBACKS.md](docs/CALLBACKS.md) for
the complete lifecycle contract. Generated API documentation is available with
`zig build docs`.

## Cloud sync

Enable the separate module in the dependency options:

```zig
const dependency = b.dependency("turso", .{
    .target = target,
    .optimize = optimize,
    .sync = true,
});
exe.root_module.addImport("turso_sync", dependency.module("turso_sync"));
```

The included example bootstraps a local database, writes and pushes a row,
pulls and applies remote changes, reports sync statistics, and checkpoints:

```sh
zig build example-sync -Dsync=true
./zig-out/bin/turso-sync local.db https://your-database.turso.io token.txt "hello"
```

`token.txt` contains the token only; the example constructs the `Bearer` header
and clears its buffers. Pass `-` only for an unauthenticated loopback server.
The standard transport requires HTTPS unless `allow_http` is deliberately
enabled; the example enables it only after parsing a loopback URL. It does not
follow redirects, redacts authorization failures, and confines file requests
to normalized root-relative paths.

`TransportOptions.authorization` remains the borrowed static-credential path.
For refreshable credentials, set `authorization_provider`: its caller-owned
callback is resolved once for every HTTP item and may return a different
borrowed header—or null—without rebuilding the database or operation.
`StandardTransport` retains no token storage and replaces native
`Authorization` headers case-insensitively only when wrapper authorization is
present.

Common blocking workflows are available directly from `turso_sync`:
`runVoid` and `runConnection` drive caller-owned typed operations; `pull`
performs wait plus conditional apply and returns a `PullSummary`; `sync`
performs push followed by pull and returns a `SyncSummary`. The latter is an
ordered convenience, not a distributed transaction or conflict-retry policy.
`run`, `Operation(T)`, and the complete I/O lifecycle remain available for
custom schedulers and manual recovery.

## Deliberate limits

- The safe local API is blocking. The raw ABI exposes asynchronous database
  opening, but the current C contract has no complete database-level polling
  interface from which to build a safe Zig driver.
- Query interruption and in-progress sync cancellation are not exposed because
  the pinned C ABI does not provide them.
- Selectable remote encryption ciphers and transform callbacks are omitted from
  the safe sync API until upstream's C conversion paths implement them.
- File-backed partial bootstrap is restricted to Linux because the pinned sync
  SDK Kit requires sparse-file support there. In-memory partial bootstrap
  remains available on every supported desktop target.
- Cloud sync is opt-in and should be treated as an evolving pre-1.0 interface.

Raw access remains available for advanced callers, but the safe API does not
invent private Rust layouts or unsupported lifecycle rules.

## Development

The primary local gates are:

```sh
zig fmt --check .
zig build test
zig build examples
zig build docs
zig build test-sync-workflows -Dsync=true
zig build test-sync-abi -Dsync=true
```

Additional steps cover Valgrind, deterministic soak/stress, 32-bit compile
safety, abrupt-exit durability, disk faults, ABI symbol manifests, clean
consumers, deterministic release archives, and local sync E2E. Run
`zig build --help` for the complete list.

Compatibility and release details live in:

- [docs/PLATFORMS.md](docs/PLATFORMS.md)
- [docs/TEST_MATRIX.md](docs/TEST_MATRIX.md)
- [docs/UPSTREAM_ABI.md](docs/UPSTREAM_ABI.md)
- [docs/UPDATING_TURSO.md](docs/UPDATING_TURSO.md)
- [docs/RELEASING.md](docs/RELEASING.md)
- [SECURITY.md](SECURITY.md)
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
- [CONTRIBUTING.md](CONTRIBUTING.md)

## License

MIT. The vendored Turso headers and source-built native library are also MIT;
see [NOTICE](NOTICE) for exact provenance.
