# Safe API ownership and usage

This document describes the implemented blocking API. The raw pinned SDK Kit ABI remains available as `turso.raw`, but ordinary application code should not need it.

## Ownership model

`Database`, `Connection`, `Statement`, `Rows`, `Transaction`, `OwnedValue`, and owned metadata values are move-only owners by convention. Zig assignment is a bitwise copy and cannot invoke a move constructor, so copying an owner and using both aliases is unsupported. When relocating an owner explicitly, assign it once and set the old variable to `undefined`.

The wrapper keeps Database and Connection control state on the heap. Relocating a Database while its Connections are alive, or a Connection while a Statement/Transaction is alive, does not invalidate the child. Destruction order still matters:

~~~text
Row < Rows/Statement < Transaction < Connection < Database
~~~

`deinit` is idempotent on the same variable after its handle has been cleared. It does not make independently copied aliases safe.

One opened Database may create independent Connections concurrently, as the
pinned C contract permits. The allocator passed to `Database.open` is also used
for Connection, statement, metadata, extension, and managed-callback state. It
must therefore be thread-safe for the full owner lifetime whenever the Database
or any derived Connections may be used concurrently, including operations,
registration replacement/unregister, and deinitialization.

## Borrowed rows and values

`Rows.next()` returns a borrowed `Row`. Its text/blob slices and native access are valid only until the next row operation, reset, finalization, cancellation, or deinit. A generation check returns `error.InvalidState` when an older Row is used after advancing while its Connection control still exists.

Use `Row.toOwned(allocator, index)`, typed decoding into `[]u8`/`OwnedValue`, or an application copy when data must outlive iteration. Borrowed `[]const u8`, `Text`, and `Blob` fields never allocate.

`Rows` never stores a caller Diagnostics pointer. Use `nextWithDiagnostics` when an iteration error needs native detail.

## Statements

The reusable prepared flow is:

~~~text
prepare -> bind/bindParams -> execute -> reset -> bind -> execute -> ... -> deinit
~~~

Reset is accepted after a completed or failed execution, not before the first execution and not after finalization. Positional prepared reuse performs no Zig allocation after preparation; this is enforced by an allocator-failure test.

For row-producing statements:

- `finish` drains/finalizes and reports any error.
- `cancel` resets pending iteration, finalizes, and reports any error.
- `deinit` performs best-effort cancellation and cleanup when the result no longer matters.

Only one live Statement or Rows value is allowed per Connection. This deliberately conservative rule matches the upstream exclusive-use contract.

## Binding and decoding

Positional bindings are one-based at the Statement API and use tuples or `[]const Value`. Named bindings require their SQL prefix for explicit calls. Struct binding removes `:`, `@`, or `$` and requires an exact, unambiguous Zig field match; numeric `?NNN` parameters are not inferred from field names.

Rows use zero-based column indices. Typed conversion is checked:

- integers must fit the requested Zig type;
- floating-point narrowing must be exact and finite-compatible;
- booleans accept only integer `0` or `1`;
- TEXT is validated UTF-8 at the binding boundary;
- BLOB is explicit through `turso.Blob`;
- missing, duplicate, and ambiguous names return distinct errors.

Typed struct decoding supports `.by_position` and `.by_name`. Owned `[]u8` and `OwnedValue` fields require an allocator; partial results are cleaned if a later field fails.

For one-shot work, `Connection.execParams` and `Connection.queryParams` accept
the same tuple, sparse positional, and named-struct forms as
`Statement.bindParams`. `Transaction` exposes matching methods. They prepare
one statement, bind with checked conversion, and execute or transfer its Rows
owner without retries. Existing `exec`/`query` calls taking `[]const Value`
remain source-compatible; parameterized batches are intentionally absent.

## Transactions and batches

`Connection.begin` supports `.deferred`, `.immediate`, `.exclusive`, and Turso's `.concurrent` mode. A live Transaction exclusively borrows the Connection; direct Connection operations and nested transactions fail. `.concurrent` requires the upstream MVCC journal-mode precondition and exposes `BusySnapshot` without automatic retries.

Commit or rollback errors preserve active transaction ownership so cleanup can be retried. `Transaction.deinit` rolls back best-effort; if rollback leaves native state uncertain, the Connection is poisoned and permits only deinitialization.

`execBatch` validates the complete input as UTF-8 and rejects an interior NUL before executing the first statement. It checks parser tail progress and returns the checked sum of rows changed. Earlier statements are not implicitly rolled back; wrap the batch in a Transaction for atomicity.

## Diagnostics and setup

`Diagnostics` owns a fixed 1024-byte buffer and never allocates. Native error strings are copied into it and released with `turso_str_deinit` on every result path. Successful operations clear supplied diagnostics.

`setup` configures process-global logging once through this wrapper. Call it before starting database worker threads. Logger event slices are borrowed only for the callback; copy retained data. Logger callbacks must be thread-safe and must return normally because a Zig panic cannot safely cross the C boundary.

Every safe `Database.open` verifies that the loaded native library reports the
exact pre-1.0 SDK Kit version selected by the build. This is the package pin
unless `-Dturso-source` selects an explicit source checkout.

## Opt-in Cloud sync

Enable sync with `-Dsync=true` and import `turso_sync`. This substitutes the
self-contained `turso_sync_sdk_kit` native library for the base SDK Kit library;
do not link both native libraries. The module is caller-driven and does not add
Milestone 5 asynchronous local database opening.

`SyncDatabase` is a move-only owner. It permits one active typed `Operation(T)`
at a time. Poll an operation until it requests I/O or completes; every checked
out `IoItem` must be completed or poisoned, checked with `close`, and then
released with infallible `deinit` before callbacks are stepped or the operation
resumes. After `.done`, `finish` extracts the typed result once. Checked
`Operation.close` then validates release and preserves the owner on failure;
`Operation.deinit` is idempotent after successful release and panics on a live
protocol precondition. `SyncDatabase` follows the same checked
`close`/infallible `deinit` split. In-progress operation teardown is rejected
because the pinned ABI does not prove cancellation convergence.

Result ownership is explicit:

- an extracted `Connection` is a normal safe Connection and must be deinited
  before its parent `SyncDatabase`;
- non-empty `Changes` must be released with infallible `deinit` or consumed
  once by `SyncDatabase.apply`; apply invalidates the Zig owner before calling
  C, including native failure paths, and later `deinit` is a no-op;
- `Stats` copies its revision and owns that allocation until `Stats.deinit`;
- request slices borrow from their `IoItem` and expire at item deinit.

`sync.run` provides the blocking driver, but its transport remains caller-owned.
A transport supplies synchronous HTTP, full-read, and atomic-full-write methods.
`StandardTransport` borrows a caller-owned allocator, `std.Io`,
`std.http.Client`, and explicitly supplied root directory for the full run. It
requires HTTPS unless `allow_http` is deliberately enabled, never follows
redirects, and accepts an optional authorization header separately from native
request headers. Transport failures cross the native boundary only as fixed
redacted categories.

Standard file handling accepts normalized, non-empty, root-relative `/` paths
and rejects absolute paths, `.`/`..`, empty components, backslashes, NUL, and
Windows drive prefixes. This is lexical confinement, not portable symlink
confinement. The caller must trust the borrowed root and prevent untrusted
changes to symlinks anywhere in its tree.

Most transport failures are poisoned into the native operation, resumed to a
terminal error, and cleaned before `sync.run` returns. If poisoning or checked
I/O-item cleanup itself cannot converge, `sync.run` returns while the caller's
`Operation` remains live; retain that value and call `sync.run` again after the
underlying condition is repaired. The pinned ABI provides no safe operation
cancellation primitive.

[examples/sync.zig](../examples/sync.zig) shows bootstrap, a local connection,
push, pull/apply, stats, checkpoint, caller-owned transport, and token handling.
`zig build test-sync-e2e -Dsync=true -Dsync-server=/path/to/tursodb` runs the
same lifecycle through two independent local clients without Cloud credentials.
