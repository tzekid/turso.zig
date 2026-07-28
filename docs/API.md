# Safe API ownership and usage

This document describes the implemented blocking API. The raw pinned SDK Kit ABI remains available as `turso.raw`, but ordinary application code should not need it.

## Ownership model

`Database`, `Connection`, `Statement`, `Rows`, `Transaction`, `BatchReport`, `OwnedValue`, and owned metadata values are move-only owners by convention. Zig assignment is a bitwise copy and cannot invoke a move constructor, so copying an owner and using both aliases is unsupported. When relocating an owner explicitly, assign it once and set the old variable to `undefined`.

The wrapper keeps Database, Connection, and prepared-statement control state on the heap. Relocating a Database while its Connections are alive, a Connection while a Statement/Transaction is alive, or a Statement while Rows leases it does not invalidate the child. Destruction order still matters:

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

The reusable non-row flow is:

~~~text
prepare -> bind/bindParams -> execute -> reset -> bind -> execute -> ... -> deinit
~~~

Reset is accepted after a completed or failed execution, not before the first execution and not after finalization. Positional prepared reuse performs no Zig allocation after preparation; this is enforced by an allocator-failure test.

Prepared row queries use either positional values or a tuple/named struct:

~~~text
prepare -> query/queryParams -> Rows -> finish/cancel/deinit -> query again
~~~

- `finish` drains to `DONE`, resets, and reports any error.
- `cancel` resets without draining and reports any error.
- `deinit` performs best-effort reset when the result no longer matters.
- `intoRows` remains an explicitly consuming compatibility path; its Rows owns
  and releases the native statement instead of returning it.

If row cleanup cannot reset the native handle, Rows still invalidates its
borrows and releases the Connection's active slot, but the prepared Statement
becomes terminal and may only be finalized or deinited. It is never reported
ready after an unproven reset.

Multiple prepared Statements may remain live and idle on one Connection. One
execute call or Rows lease owns the connection-wide active slot; other
statement and connection operations return `error.InvalidState` until that
execution is released. Function/collation registration and extension-policy
mutation remain blocked while any prepared statement is live because compiled
programs may retain those registrations. Transaction termination and
Connection close likewise require all statement owners to be released.

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
remain source-compatible.

## Feature configuration

`FeatureSet` exposes every token parsed by the pinned v0.7.1 SDK Kit:
`views`, `index_method`, `custom_types`, `autovacuum`, `vacuum`, `encryption`,
`attach`, `generated_columns`, `multiprocess_wal`, `without_rowid`, and
`mvcc_passive_checkpoint`. Enabled typed fields render once in that canonical
order. Supplying `EncryptionOptions` implicitly enables `encryption` for both
local and sync database construction.

`unchecked_extra` forwards experimental names that this binding does not
recognize. Each name must be non-empty, trimmed valid UTF-8 without a comma or
NUL. Duplicates and every name already represented by a typed field are
rejected before native construction. Accepted unchecked names retain caller
order after the typed fields.

The escape hatch is deliberately named `unchecked`: the upstream parser
silently ignores unknown names, so successful validation and database opening
do not prove that a feature exists or took effect. Unchecked names receive no
compatibility guarantee and should be replaced with typed fields when the
package pin learns them.

## Transactions and batches

`Connection.begin` supports `.deferred`, `.immediate`, `.exclusive`, and Turso's `.concurrent` mode. A live Transaction exclusively borrows the Connection; direct Connection operations and nested transactions fail. `.concurrent` requires the upstream MVCC journal-mode precondition and exposes `BusySnapshot` without automatic retries.

Commit or rollback errors preserve active transaction ownership so cleanup can be retried. `Transaction.deinit` rolls back best-effort; if rollback leaves native state uncertain, the Connection is poisoned and permits only deinitialization.

`execBatch` is the lightweight parameterless SQL-script API. It validates the
complete input as UTF-8 and rejects an interior NUL before executing the first
statement. It checks parser tail progress and returns the checked sum of rows
changed. Earlier statements are not implicitly rolled back; wrap the script in
a Transaction for atomicity.

`executeBatch` is the structured counterpart. Each `BatchItem` contains one
statement and `.none`, `.positional`, or explicitly `.named` runtime
parameters. All SQL strings, TEXT values, and named descriptors are validated
before the first statement executes. A parameter-count or SQL/name mismatch
that depends on native preparation fails before that affected statement is
executed.

`Connection.executeBatch` requires an explicit transaction policy:

- `.none` executes sequentially and retains normal effects from completed
  entries if a later entry fails;
- `.deferred`, `.immediate`, `.exclusive`, or `.concurrent` starts a
  wrapper-owned transaction, commits only after all entries complete, and
  rolls back on execution, materialization, or commit failure;
- rollback failure returns the rollback error, records `.rollback_failed`, and
  poisons the Connection so only deinit remains valid.

`Transaction.executeBatch` already runs in its caller-owned transaction. It
accepts only `.transaction = .none`, leaves that transaction active on success
or failure, and rejects nested transaction modes.

The caller initializes `BatchReport` with `.{};` and always calls its
idempotent `deinit`. Errors are returned normally, while `completed`,
`failed_index`, `entries()`, and `transaction_outcome` retain exact progress.
Each completed entry reports rows changed and the connection's last insert row
ID.

`.changes_only` drains query rows without allocating them.
`.materialize_rows` copies column metadata and typed rows into report-owned
storage. Its caller-selected limits are aggregate across the report:
`max_rows` counts rows, `max_items` counts column descriptors plus row values,
and `max_bytes` counts owned metadata, TEXT, and BLOB bytes. Limit exhaustion
returns `error.MaterializationLimitExceeded`; partial allocations are cleaned
before the report is returned. No batch path retries automatically.

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

The common blocking workflows are:

- `runVoid` and `runConnection`, which infer the operation result type while
  retaining a caller-owned `*Operation(T)` for checked recovery;
- `pull`, which waits and conditionally applies an owned `Changes`, returning
  a `PullSummary` that distinguishes no changes from a completed apply;
- `sync`, which completes push and then calls `pull`, returning a
  `SyncSummary`.

`sync` is sequencing only. Push and pull are separate native operations, not a
distributed transaction, and the helper performs no Busy/BusySnapshot,
conflict, or cancellation retry. There is deliberately no stats convenience:
`Stats` ownership remains explicit. `sync.run`, `Operation(T)`, `IoItem`, and
the callback steps remain exposed for custom schedulers.

All workflows borrow the allocator, database, transport, and transport options
for the synchronous call. `runVoid` and `runConnection` take operation
pointers rather than consuming values: if native I/O-item recovery fails, the
caller retains the exact owner and can retry it. `pull` and `sync` create their
intermediate operations internally; callers that need to recover from the
catastrophic case where native poison/close itself cannot converge must use the
low-level operations instead, because the pinned ABI has no cancellation
primitive that would let a helper discard a hidden live operation safely.

The transport remains caller-owned.
A transport supplies synchronous HTTP, full-read, and atomic-full-write methods.
`StandardTransport` borrows a caller-owned allocator, `std.Io`,
`std.http.Client`, and explicitly supplied root directory for the full run. It
requires HTTPS unless `allow_http` is deliberately enabled, never follows
redirects, and accepts wrapper authorization separately from native request
headers. `TransportOptions.authorization` is the source-compatible static
borrow. `authorization_provider` is an optional erased context plus callback:
the driver invokes it exactly once for each HTTP item, immediately before the
caller-owned transport, and never for full-file items. Its result is
authoritative even when the static field is populated; returning null
deliberately disables wrapper injection for that request and preserves native
headers.

The provider's optional header and both slices remain caller-owned and need
only stay valid until the synchronous transport `request` method returns.
Neither the driver nor `StandardTransport` stores or owns token bytes.
`StandardTransport` validates static and provider headers through the same RFC
token/CR-LF boundary, and replaces every case-insensitive native
`Authorization` header with exactly one wrapper header when one is present.
Redirect handling remains `.unhandled`, so wrapper authorization is never
automatically forwarded to another origin.

A single `run` invokes its provider serially, but the binding does not
synchronize a shared provider context across separate concurrent runs. The
caller owns that synchronization and must not re-enter the same database or
operation from the callback. Provider errors are replaced with the fixed
`sync authorization provider failure` poison/diagnostic category; returned
header bytes and callback error details are never formatted. Transport failures
likewise cross the native boundary only as fixed redacted categories.

Standard file handling accepts normalized, non-empty, root-relative `/` paths
and rejects absolute paths, `.`/`..`, empty components, backslashes, NUL, and
Windows drive prefixes. This is lexical confinement, not portable symlink
confinement. The caller must trust the borrowed root and prevent untrusted
changes to symlinks anywhere in its tree.

Partial bootstrap is accepted for file-backed databases only on Linux. The
pinned sync SDK Kit uses Linux sparse-file I/O for that mode; its non-Linux
fallback does not implement the required hole detection. `:memory:` uses the
native memory I/O path and remains valid with partial bootstrap on every
supported desktop target. Unsupported file-backed configurations fail with
`error.UnsupportedPartialBootstrap` before allocation or native construction.

Most transport failures are poisoned into the native operation, resumed to a
terminal error, and cleaned before `sync.run` returns. If poisoning or checked
I/O-item cleanup itself cannot converge, `sync.run` returns while the caller's
`Operation` remains live; retain that value and call `sync.run`, `runVoid`, or
`runConnection` again after the underlying condition is repaired. The pinned
ABI provides no safe operation cancellation primitive.

[examples/sync.zig](../examples/sync.zig) shows bootstrap, a local connection,
push, pull/apply, stats, checkpoint, caller-owned transport, and token handling.
`zig build test-sync-e2e -Dsync=true -Dsync-server=/path/to/tursodb` runs the
same lifecycle through two independent local clients and the public
`runVoid`, `runConnection`, `sync`, and `pull` helpers without Cloud
credentials. Stats deliberately remains on the low-level typed driver.
