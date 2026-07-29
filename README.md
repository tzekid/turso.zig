# turso.zig

[![CI](https://github.com/tzekid/turso.zig/actions/workflows/ci.yml/badge.svg)](https://github.com/tzekid/turso.zig/actions/workflows/ci.yml)
[![Zig 0.16.0](https://img.shields.io/badge/Zig-0.16.0-f7a41d)](https://ziglang.org/download/)
[![MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A small, unofficial Zig binding for the
[Turso](https://github.com/tursodatabase/turso) database.

>Turso is an in-process SQL database written in Rust and designed for SQLite
compatibility. This package builds or links Turso's public SDK Kit C library,
exposes its C API under `turso.raw`, and provides a safer Zig API for normal
use. A Zig program can open an in-memory or local file database without running
a separate database server. Remote synchronization is available as an opt-in
module.

## Contents

- [Project status](#project-status)
- [Install](#install)
- [First program](#first-program)
- [Common tasks](#common-tasks)
  - [Bind values instead of formatting SQL](#bind-values-instead-of-formatting-sql)
  - [Decode a row into a struct](#decode-a-row-into-a-struct)
  - [Use a transaction](#use-a-transaction)
- [Runnable examples](#runnable-examples)
- [What is available](#what-is-available)
- [Limits and expectations](#limits-and-expectations)
- [Optional remote sync](#optional-remote-sync)
- [Ownership basics](#ownership-basics)
- [Build options](#build-options)
- [SDK Kit coverage](#sdk-kit-coverage)
- [Platforms and validation](#platforms-and-validation)
- [More documentation](#more-documentation)
- [License](#license)

## Project status

This is currently a hobby project I spun up with the help of LLMs in a couple of days for use in my personal projects.

Always happy to receive feedback / critique.

The project is new, unofficial, and pre-1.0. It is not an official Turso SDK
and does not promise long-term API stability (yet). Test it against your own
workload and keep backups of data you care about.

## Install

The default build needs:

- Zig 0.16.0
- Rust and Cargo 1.88 or newer
- a C toolchain

Add the current tagged release to your project:

```sh
zig fetch --save=turso git+https://github.com/tzekid/turso.zig#v0.1.0
```

The first build can take a while because the default backend compiles Turso
from source. `v0.1.0` pins Turso SDK Kit `v0.7.0`.

The `master` branch contains unreleased `0.2.0` work and pins SDK Kit `v0.7.1`.
If you want to try the code documented on the current branch:

```sh
zig fetch --save=turso git+https://github.com/tzekid/turso.zig#master
```

`zig fetch` records the resolved commit in `build.zig.zon`. Keep that hash in
version control rather than depending on a moving branch name.

Add the dependency's module to your executable in `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const turso = b.dependency("turso", .{
        .target = target,
        .optimize = optimize,
    });

    const app = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "turso", .module = turso.module("turso") },
            },
        }),
    });
    b.installArtifact(app);
}
```

## First program

Create `src/main.zig`:

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
        "INSERT INTO users(name) VALUES (?1)",
        .{"Ada"},
        .{},
    );

    var rows = try connection.query(
        "SELECT id, name FROM users",
        &.{},
        .{},
    );
    defer rows.deinit();

    while (try rows.next()) |row| {
        std.debug.print("{d}: {s}\n", .{
            try row.get(i64, 0),
            try row.get([]const u8, 1),
        });
    }
}
~~~

Build and run it:

```sh
zig build
./zig-out/bin/app
```

The output is:

```text
1: Ada
```

Use a path such as `app.db` instead of `:memory:` when the database should
survive after the process exits.

## Common tasks

### Bind values instead of formatting SQL

`execParams` and `queryParams` accept tuples for positional parameters and
structs for named parameters:

```zig
_ = try connection.execParams(
    "INSERT INTO users(id, name) VALUES (:id, :name)",
    .{ .id = @as(i64, 2), .name = "Grace" },
    .{},
);

var rows = try connection.queryParams(
    "SELECT name FROM users WHERE id = ?1",
    .{@as(i64, 2)},
    .{},
);
defer rows.deinit();
```

Use a prepared `Statement` when the same SQL runs repeatedly. A statement can
be rebound after an execution is finished or cancelled.

### Decode a row into a struct

```zig
const User = struct {
    id: i64,
    name: []const u8,
};

while (try rows.nextAs(User, null, .{ .mode = .by_name })) |user| {
    std.debug.print("{d}: {s}\n", .{ user.id, user.name });
}
```

The text in this example is borrowed from the current row. See
[Ownership basics](#ownership-basics) before storing it.

### Use a transaction

```zig
var transaction = try connection.begin(.immediate, .{});
defer transaction.deinit();

_ = try transaction.execParams(
    "INSERT INTO users(name) VALUES (?1)",
    .{"Linus"},
    .{},
);
try transaction.commit(null);
```

If control leaves the scope before `commit` or `rollback`, `deinit` attempts a
rollback.

## Runnable examples

Every example is built from the same public module a consumer imports:

| Example | Covers | Command |
| --- | --- | --- |
| [basic.zig](examples/basic.zig) | In-memory CRUD and typed column access | `zig build example-basic` |
| [file.zig](examples/file.zig) | File persistence, reopening, and last insert row ID | `zig build example-file` |
| [values.zig](examples/values.zig) | Every SQL value kind and copies that outlive a row | `zig build example-values` |
| [diagnostics.zig](examples/diagnostics.zig) | Error details, busy timeout, and statement metadata | `zig build example-diagnostics` |
| [prepared.zig](examples/prepared.zig) | Reusable statements and positional/named parameters | `zig build example-prepared` |
| [transaction.zig](examples/transaction.zig) | Commit, explicit rollback, and rollback on scope exit | `zig build example-transaction` |
| [batch.zig](examples/batch.zig) | Atomic/non-atomic structured batches and bounded row capture | `zig build example-batch` |
| [ergonomic.zig](examples/ergonomic.zig) | Named binding, struct decoding, and extension controls | `zig build example-ergonomic` |
| [functions.zig](examples/functions.zig) | Scalar/aggregate functions and collations | `zig build example-functions` |
| [encryption.zig](examples/encryption.zig) | Local encrypted database setup | `zig build example-encryption` |
| [sync.zig](examples/sync.zig) | Caller-driven remote synchronization | `zig build example-sync -Dsync=true` |

Run the normal example set with:

```sh
zig build examples
```

The encryption example is compiled but not run automatically because it needs
a key file. Add `-Dsync=true` to the aggregate command to compile the sync
example; it is not run because it needs an endpoint.

## What is available

The safe API currently covers:

- memory and file databases
- one-shot and reusable prepared statements
- positional and named parameters
- null, integer, real, text, and blob values
- typed column access and struct decoding
- transactions, SQL scripts, and structured batches
- busy timeouts, autocommit state, last insert row ID, and metadata
- scalar and aggregate functions, collations, and opt-in extension loading
- local encryption and VFS selection
- optional caller-driven remote synchronization

The exact pinned C declarations remain available under `turso.raw` for code
that needs them.

## Limits and expectations

- The safe database API is blocking. The C ABI declares asynchronous database
  opening, but it does not expose the complete database-level polling interface
  needed for a safe Zig event-loop driver.
- The C ABI does not expose query interruption or cancellation of an in-progress
  sync operation.
- Sync is opt-in and especially likely to change before 1.0. Its deterministic
  lifecycle tests use C fixtures, and its real end-to-end test uses a local
  `tursodb` server. It has not been tested here against credentialed Turso
  Cloud.
- Remote cipher selection and transform callbacks are not in the safe sync API
  because the pinned upstream C path does not implement them completely.
- There are no published prebuilt binaries. The normal installation builds the
  native SDK Kit from source.
- Android and iOS are not claimed. Browser/WASM is unsupported. Windows ARM64
  is not currently part of the tested release matrix.

This binding stays within the public SDK Kit C ABI. It does not bind private
Rust layouts or symbols, so features available only to Turso's Rust-backed
language bindings cannot be recreated safely here without an upstream C API.

## Optional remote sync

Sync uses a separate module and native library. Enable it in `build.zig`:

```zig
const turso = b.dependency("turso", .{
    .target = target,
    .optimize = optimize,
    .sync = true,
});

app.root_module.addImport(
    "turso_sync",
    turso.module("turso_sync"),
);
```

The included example creates or opens a local database, writes and pushes a
row, pulls and applies remote changes, prints statistics, and checkpoints:

```sh
zig build example-sync -Dsync=true
./zig-out/bin/turso-sync local.db https://your-database.turso.io token.txt "hello"
```

`token.txt` contains the token only. Use `-` only for an unauthenticated
loopback server. The example enables plain HTTP only for a parsed loopback URL;
other endpoints require HTTPS.

The module exposes typed operations plus `runVoid`, `runConnection`, `pull`,
and `sync` helpers. The caller still owns scheduling, transport, credentials,
and retry policy. Read [the sync example](examples/sync.zig) before integrating
it.

## Ownership basics

`Database`, `Connection`, `Statement`, `Rows`, `Transaction`, sync operations,
and owned values are move-only by convention. Zig does not enforce move-only
types, so do not copy these owners. Release children before their parents:

```text
Row < Rows/Statement < Transaction < Connection < Database
```

A text or blob slice returned from a `Row` borrows the native current row. It
expires on the next operation on that statement. Use `row.toOwned` or an owned
typed decode when the value must survive iteration.

Only one execution or `Rows` lease can be active on a connection at a time.
Call `finish`, `cancel`, or `deinit` before using the connection for another
operation. The wrapper checks these lifetimes and reports or panics on invalid
destruction order, but it cannot detect an owner copied by value.

The full contract is in [docs/API.md](docs/API.md). Callback-specific lifetime
and error rules are in [docs/CALLBACKS.md](docs/CALLBACKS.md).

## Build options

Most users can keep the defaults:

| Option | Default | Purpose |
| --- | --- | --- |
| `native` | `source` | Build the pinned SDK Kit, or use `system` for an installed copy |
| `linkage` | `static` | Link `static` or `dynamic` |
| `encryption` | `true` | Build local encryption support |
| `fts` | `false` | Build full-text-search support |
| `sync` | `false` | Use the sync SDK Kit and expose `turso_sync` |
| `native-path` | unset | Prefix containing an installed SDK Kit |
| `turso-source` | unset | Build against an explicit Turso checkout |
| `rust-target` | inferred | Override Cargo's target triple |
| `allow-source-cross` | `false` | Acknowledge an externally configured Cargo cross toolchain |

For example, to link an SDK Kit installed under `/opt/turso`:

```zig
const turso = b.dependency("turso", .{
    .target = target,
    .optimize = optimize,
    .native = "system",
    .@"native-path" = "/opt/turso",
});
```

Source-mode cross compilation requires an explicitly configured Cargo linker
and sysroot. For release cross builds, a target-native system library is
usually simpler. Windows source builds use the MSVC ABI, so select a matching
Zig target such as `-Dtarget=x86_64-windows-msvc`.

See [docs/PLATFORMS.md](docs/PLATFORMS.md) for system library layout, dynamic
runtime search paths, cross-compilation boundaries, and the evidence required
to claim a platform.

## SDK Kit coverage

This table describes the relationship between the pinned public C ABI and the
safe Zig layer. It is not a comparison with SQLite's full C API.

| SDK Kit area | Raw declaration | Safe Zig API | Notes |
| --- | --- | --- | --- |
| Database open/connect/close | Yes | Yes | Memory and file paths |
| Statements and parameters | Yes | Yes | One-shot, reusable, positional, and named |
| Rows, values, and metadata | Yes | Yes | Borrowed and owned values; typed decoding |
| Transactions | Yes | Yes | Deferred, immediate, exclusive, and concurrent |
| SQL batch execution | Yes | Yes | Raw SQL scripts plus wrapper-level structured batches |
| Busy timeout/autocommit/last row ID | Yes | Yes | Direct safe wrappers |
| Functions and collations | Yes | Yes | Managed Zig callbacks |
| Extension loading | Yes | Yes | Disabled until explicitly enabled |
| Local encryption and VFS selection | Yes | Yes | Build feature and runtime configuration |
| Remote synchronization | Yes | Yes, opt-in | Caller-driven operations and transport |
| Async database driver | Partial | No | C polling contract is incomplete |
| Query interrupt | No | No | Requires an upstream ABI addition |
| In-progress sync cancellation | No | No | Requires an upstream ABI addition |
| Remote cipher selection | Declared | No | Dropped by the pinned upstream conversion path |
| Sync transform callbacks | No | No | Not present in the public sync header |

For the symbol-level audit and deliberately omitted surfaces, see
[docs/UPSTREAM_ABI.md](docs/UPSTREAM_ABI.md).

## Platforms and validation

The target-native CI and packaging matrix currently covers:

| Platform | Architectures |
| --- | --- |
| Linux glibc | x86_64, aarch64 |
| Linux musl | x86_64, aarch64 |
| macOS | x86_64, aarch64 |
| Windows MSVC | x86_64 |

Linux also runs fault injection, ownership checks under Valgrind,
deterministic soak tests, package extraction tests, and a real two-client sync
round trip through a local `tursodb` server. Fixture-backed tests exercise
failure states and lifecycle edges that are difficult to force through the
real library.

Useful local checks are:

```sh
zig fmt --check .
zig build test
zig build examples
zig build docs
zig build test-sync-workflows -Dsync=true
zig build test-sync-abi -Dsync=true
```

The complete coverage map, including what uses the real native library and what
uses fixtures, is in [docs/TEST_MATRIX.md](docs/TEST_MATRIX.md).

## More documentation

- [Safe API and ownership](docs/API.md)
- [Managed callbacks](docs/CALLBACKS.md)
- [Platform support](docs/PLATFORMS.md)
- [Test matrix](docs/TEST_MATRIX.md)
- [Pinned upstream ABI](docs/UPSTREAM_ABI.md)
- [Updating Turso](docs/UPDATING_TURSO.md)
- [Release process](docs/RELEASING.md)
- [Security policy](SECURITY.md)
- [Contributing](CONTRIBUTING.md)

Generate the API reference with `zig build docs`; it is written under
`zig-out/docs`.

## License

MIT. The vendored Turso headers and the source-built native library are also
MIT; [NOTICE](NOTICE) records their exact upstream tag, commit, and hashes.
