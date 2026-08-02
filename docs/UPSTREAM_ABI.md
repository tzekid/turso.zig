# Upstream SDK Kit ABI audit

## Scope and authority

The detailed stable baseline below is pinned to final annotated tag `v0.7.1` (tag object
`31cdceeb07d3b294e5b2f13b03cfdbbf59769b78`) and its peeled source commit
`4a88feb7caef869c16f6215b6dc51eafd5b3e54e`. Links below use that immutable
release commit.

`master` currently promotes development channel `main` at commit
`e99973a43e906325f46f27e6bd3fa404dd5dd31b`, declared version
`0.8.0-pre.2`. The base header body remains byte-identical to the stable
baseline. The sync header changes comments only; its promoted body digest is
`f9de9cb7eab356e59fd7efdbc02c6a35598588202297535436ecfeaa8ad7bda1`.
The development delta audit is recorded below. Re-audit it on every promoted
commit.

The audited upstream header body digests are:

- `sdk-kit/turso.h`:
  `14ee49b4f6c00e3f8c3c710b4df1c316ecc0802e1d8b19815d8caab09f2b70cb`
- `sync/sdk-kit/turso_sync.h`:
  `38b9dc73fc2fe45c3d86d69ff2ad48b8c99d693a4462514ea50fb876aba6ee35`

Moving upstream refs are discovery inputs only. Required builds use the exact
promoted commit. Stable release authority still requires an annotated tag and
cannot use the development commit.

## Development delta: v0.7.1 to main 6e527a75

The reviewed relevant diff changes six files: the workspace manifest and
lockfile, `sdk-kit/src/lib.rs`, `sdk-kit/src/rsapi.rs`,
`sync/sdk-kit/src/rsapi.rs`, and sync-header comments. `LICENSE.md`,
`NOTICE.md`, the base C header, C function declarations, exported symbol
allowlists, crate feature names, native library names, and Rust `1.88`
toolchain requirement are unchanged.

The base SDK refactors internal VFS selection to a typed `IoBackend` and routes
database opening through the new core open API. The C strings and behavior
exposed to this binding remain the same; target validation and the blocking
`async_io = false` policy are retained. Workspace dependency and lockfile
changes alter the native implementation and therefore require the full native
matrix, but do not add native link requirements observed by the ABI gate.

Sync now interprets C `logical_mvcc_pull = false` as protocol auto-detection
and persistence, while `true` remains an explicit MVCC override. Fresh MVCC
bootstrap also catches up through the durable logical-log tail before
connection. This is a behavior change, not an ABI layout change. The wrapper's
default `false` now gains auto-detection; its explicit opt-in remains a force
override. Ownership, transfer, destructor, callback, and error-allocation
declarations are unchanged.

The promoted commit passed translated-declaration comparison, base exported
symbols and C probes, runtime-version match/mismatch, native safe suites, and
the deterministic sync lifecycle/transport fixtures locally. Target-native
hosted and extended results remain the authority for their respective platform
claims.

The implementation should resolve conflicting evidence in this order:

1. Exported C functions implemented in `sdk-kit/src/capi.rs` and
   `sync/sdk-kit/src/capi.rs`.
2. The two public headers, [`sdk-kit/turso.h`](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/sdk-kit/turso.h)
   and [`sync/sdk-kit/turso_sync.h`](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/sync/sdk-kit/turso_sync.h).
3. Rust SDK Kit behavior in `rsapi.rs`, core code, and upstream tests.
4. README examples. The current SDK Kit README is stale and is not an ABI
   authority; see [Known discrepancies](#known-discrepancies-and-upstream-gaps).

The supported boundary is C only. Do not bind Rust symbols or infer the layout of
opaque Rust types.

## Native artifacts and linkage evidence

Both crates explicitly produce Rust `lib`, `cdylib`, and `staticlib` artifacts:

- Base: [`sdk-kit/Cargo.toml:16-18`](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/sdk-kit/Cargo.toml#L16-L18), native name `turso_sdk_kit`.
- Sync: [`sync/sdk-kit/Cargo.toml:13-15`](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/sync/sdk-kit/Cargo.toml#L13-L15), native name `turso_sync_sdk_kit`.

On this `x86_64-unknown-linux-gnu` host, the pinned checkout was built outside
the checkout with:

```text
CARGO_TARGET_DIR=/tmp/turso-zig-upstream-audit-target \
  cargo rustc -p turso_sdk_kit --lib --locked -- --print native-static-libs
CARGO_TARGET_DIR=/tmp/turso-zig-upstream-audit-target \
  cargo rustc -p turso_sync_sdk_kit --lib --locked -- --print native-static-libs
```

Both reported, in significant order:

```text
-ldl -lgcc_s -lutil -lrt -lpthread -lm -ldl -lc
```

This is evidence for this host and toolchain, not a portable hard-coded list.
Capture `--print native-static-libs` for every release target. The sync artifact
is self-contained with respect to the base SDK Kit: the built sync `.so` exports
all 48 base `turso_*` symbols plus 29 sync symbols and has no dynamic dependency
on `libturso_sdk_kit.so`. Its static archive also defines the base symbols.
Therefore a sync-enabled consumer should link `turso_sync_sdk_kit`, not blindly
link both Rust static libraries and risk duplicate Rust dependency graphs.
Prove the selected policy with a final executable link on every target.
The Zig build implements this as the opt-in `-Dsync=true` library substitution:
it exposes `turso_sync`, installs the sync header, and selects the sync native
artifact for both the base and sync modules.

The generated Rust bindings are checked in and are **not** regenerated by
`build.rs`; regeneration is a manual `bindgen.sh` step
([base script](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/sdk-kit/bindgen.sh),
[sync script](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/sync/sdk-kit/bindgen.sh)).
ABI drift checks must compare the public headers, exported symbols, and Zig
layout independently.

## Cross-cutting pointer, string, and error rules

### Inputs and outputs

- All opaque handles are single-owner tokens at the C boundary. A handle must
  be passed to its matching `*_deinit` exactly once. `*_deinit(NULL)` is a no-op;
  any other stale, foreign, or twice-freed pointer is undefined behavior.
- Many output pointers are dereferenced without a null check, including database,
  connection, statement, operation, result, and IO-item outputs. The Zig wrapper
  must always pass a valid local output pointer and initialize it to null/default
  before the call. Treat outputs as initialized only for the documented success
  status.
- Zero-terminated string inputs must be non-null unless explicitly optional,
  valid UTF-8, and free of interior NUL. The implementation copies configuration,
  SQL, names, and paths during the call, so caller buffers may be released after
  the call returns (`sdk-kit/src/rsapi.rs:230-305`, `307-355`).
- `turso_slice_ref_t` never transfers ownership
  ([`turso.h:8-17`](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/sdk-kit/turso.h#L8-L17)).
  Base text/blob bind functions accept `(NULL, 0)` and copy the bytes. Sync
  completion helpers reject a null slice even when its length is zero, so pass a
  non-null sentinel for empty poison/buffer slices.
- Any C string returned as an error, column name/type, or parameter name is a
  Turso allocation. Copy it if needed, then call `turso_str_deinit` exactly once.
  `turso_version()` is the exception: it returns static storage and must never be
  freed ([`turso.h:173-175`](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/sdk-kit/turso.h#L173-L175)).

### Status and native messages

The numeric status ABI is fixed by
[`turso.h:19-36`](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/sdk-kit/turso.h#L19-L36):

| Code | Meaning | Zig treatment |
| --- | --- | --- |
| `0 OK` | Synchronous API success | success |
| `1 DONE` | Statement/operation completed | state, not error |
| `2 ROW` | Current statement row available | state, not error |
| `3 IO` | Caller must drive IO | state, not error |
| `4 BUSY` | Locked / statement in progress | typed error; no automatic retry |
| `5 INTERRUPT` | Interrupted | typed error |
| `6 BUSY_SNAPSHOT` | Stale snapshot | typed error; transaction retry decision belongs to caller |
| `127 ERROR` | Generic engine/sync error | typed error plus native message |
| `128 MISUSE` | Invalid state, pointer, index, or forbidden concurrency | typed error plus native message where available |
| `129..134` | Constraint, readonly, full, not-a-db, corrupt, IO error | distinct typed errors |

On error, functions with `error_opt_out` allocate a message only when the output
pointer is non-null (`sdk-kit/src/rsapi.rs:445-471`). They do not clear the slot on
success. Always initialize the slot to null, copy/free any non-null result on
every status path, and clear Zig diagnostics on success. Positional bind functions
have no error output at all; only their status survives
(`sdk-kit/src/capi.rs:882-977`). Sentinel-returning getters also discard error
detail; validate state and indices in the safe layer.

## Base SDK Kit ownership and state machines

### Global setup and logging

`turso_setup` requires a non-null config. Logging setup is process-global and the
tracing subscriber is installed through a Rust `Once`; later calls return success
but cannot replace the installed filter/subscriber (`sdk-kit/src/rsapi.rs:555-633`).
The logger callback may run from arbitrary Turso threads. Every `turso_log_t`
field is borrowed only for that callback invocation
([`turso.h:190-197`](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/sdk-kit/turso.h#L190-L197)).
The callback function must remain valid until process shutdown, must copy retained
data, and must not panic or call unsafe re-entrant wrapper operations.

### Handle hierarchy

| Handle | Create/transfer | Valid use | Terminal action |
| --- | --- | --- | --- |
| `turso_database_t` | `turso_database_new` on `OK` | Open once; after open, create independent connections concurrently | `turso_database_deinit` once, after wrapper-owned children |
| `turso_connection_t` | `turso_database_connect` on `OK`, or one-shot sync extraction | Exclusive use only; no concurrent calls | `close` then `deinit`; `deinit` is still required if close fails |
| `turso_statement_t` | prepare on `OK` and non-null output | Exclusive use; row borrows are tied to it | `finalize` as required, then `deinit` once |

The header explicitly makes Database concurrently usable but Connection and
Statement exclusive
([`turso.h:161-171`](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/sdk-kit/turso.h#L161-L171)).
Rust compile-time checks confirm Database is `Send + Sync`, while Connection and
Statement are only `Send` (`sdk-kit/src/rsapi.rs:27-34`). A shared native guard
returns `MISUSE: concurrent use forbidden` for some overlapping statement work
(`sdk-kit/src/lib.rs:28-61`), but it does not cover every API. Do not rely on that
guard as memory safety: the safe Zig types must enforce/document exclusivity.

Keep the public wrapper hierarchy Database -> Connection -> Statement/Rows even
though internal Rust `Arc`s can keep storage alive. This prevents use after the C
owner token is deinitialized.

### Database open

`turso_database_new` copies configuration but does not open storage. Calling
`connect` before open returns `MISUSE`. In caller-driven mode, repeated open calls
advance the stored Opening state; after Done, the implementation returns success
again (`sdk-kit/src/rsapi.rs:729-850`). The header nevertheless requires one
logical, non-concurrent open, which is the contract the safe wrapper should expose.

When `async_io == 0`, open drives IO internally and returns `OK` or an error. When
non-zero, it can return `IO`, but `turso.h` exposes neither the returned completion
nor a database-level run-IO function. This makes safe caller-driven database open
incomplete. Production local mode must force `async_io = 0` until upstream adds
the missing driver. Statement-level `run_io` does not complete database open.

Encryption requires both cipher and hex key, and also the `encryption`
experimental feature (`sdk-kit/src/rsapi.rs:314-355`, `756-759`). VFS restrictions
are runtime checked: `io_uring` is Linux-only and `experimental_win_iocp` is
Windows-only (`sdk-kit/src/rsapi.rs:670-724`). Unknown experimental feature names
are silently ignored (`sdk-kit/src/rsapi.rs:184-213`). The wrapper therefore
exposes every pinned parser token as a typed field and confines unknown names
to the validated, explicitly unsupported `unchecked_extra` escape hatch.

### Connection close

`turso_connection_close` requires no ongoing operations
([`turso.h:355-362`](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/sdk-kit/turso.h#L355-L362)).
It invalidates/finalizes every tracked outstanding statement before closing core
state (`sdk-kit/src/rsapi.rs:1179-1196`). Statement wrappers therefore become
unusable after connection close even if their outer native pointers still exist;
they must still be deinitialized. Do not call close concurrently with any child.

`set_busy_timeout_ms` silently ignores negative durations and invalid pointers;
the boolean/rowid getters return `false`/`0` on invalid pointers. Validate in Zig
rather than interpreting these defaults as native state (`sdk-kit/src/capi.rs:115-149`).

### Statement execution, bindings, rows, and metadata

- Bind positions and parameter-name lookup are 1-based. Named lookup requires the
  SQL prefix (`:`, `@`, `$`, or `?N`); it returns `-1` on any failure. The safe
  wrapper may implement named bind as lookup followed by positional bind.
- TEXT and BLOB bind calls copy input immediately. TEXT is UTF-8 validated and may
  contain embedded NUL because it is length-delimited (`sdk-kit/src/capi.rs:932-977`).
- `step` returns `ROW`, `DONE`, or (only in caller-driven mode) `IO`. `execute`
  skips all produced rows and runs to `DONE`/`IO`; its `rows_changed` output is
  optional and is not reliable after an error (`sdk-kit/src/capi.rs:472-508`).
- A current row exists only after `ROW`. Text/blob pointers are borrowed until
  the next statement operation (`step`, `execute`, `run_io`, `reset`, `finalize`,
  close, or deinit); copy before any such call
  ([`turso.h:471-483`](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/sdk-kit/turso.h#L471-L483)).
- Wrong-kind and invalid getters return ambiguous defaults: unknown kind,
  byte-count `-1`, pointer null, integer `0`, and real `0.0`
  (`sdk-kit/src/capi.rs:713-827`). Check kind and bounds first.
- Column name/type and parameter name results are independent owned C strings;
  free each with `turso_str_deinit`. Rich type-info getters intentionally collapse
  unsupported feature, finalized state, expressions, and bad index into null/
  `NONE` (`sdk-kit/src/rsapi.rs:1499-1515`).
- `reset` aborts pending execution and clears all bindings. `finalize` may itself
  advance a running statement and return `IO`; on completion it drops the inner
  statement and further stateful calls return `MISUSE` or sentinel defaults
  (`sdk-kit/src/rsapi.rs:1517-1543`). The outer handle must still be deinited.

### Managed functions and collations

Callback arguments are immutable and valid only for the callback invocation
([`turso.h:131-150`](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/sdk-kit/turso.h#L131-L150)).
Never retain their nested text/blob/error pointers.

Registration owns the context after success. Its context destructor runs when the
registration is replaced, unregistered, or finally dropped; collation contexts
follow the same rule (`core/function.rs:24-57`, `191-206`). Aggregate init returns
a separately owned per-aggregate state. The aggregate destructor can run on
normal finalization and on step/error cleanup (`core/vdbe/execute.rs:6653-6661`,
`6718-6733`, `6850-6871`). Implement every destructor as exactly-once-safe for its
own allocation category; do not make context and aggregate state alias ownership.

The pinned core has a multi-aggregate error-path gap: when one external
aggregate step fails, it destroys that accumulator, but `ProgramState.reset`
can null sibling external-aggregate registers without calling their aggregate
destructors. The safe wrapper therefore tracks every live external aggregate
state per exclusive Connection. Normal native destructors detach states; only
after native reset/finalize/deinit has discarded its pointers does the wrapper
destroy any survivor. Raw callers do not receive this workaround.

Turso copies every scalar, aggregate-step, and aggregate-final return before
calling the registered value destructor. A Zig registration returning text,
blob, or error **must provide its own value destructor**. If none is provided,
core calls a Rust-specific internal free routine that assumes the nested objects
were allocated as Rust `Box`/`Vec` layouts (`extensions/core/src/types.rs:449-531`),
which is invalid for Zig allocations. Integer, real, and null returns contain no
owned nested payload. No Zig error or panic may unwind across any C callback.

## Sync SDK Kit

### Conservative concurrency contract

`turso_sync_operation_t` is explicitly exclusive
([`turso_sync.h:146-154`](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/sync/sdk-kit/turso_sync.h#L146-L154)).
Upstream's Go example also states that push/pull and checkpoint must be serialized
(`examples/go/sync/sync.go:1-11`). The Rust implementation holds one sync-engine
mutex across async work (`sync/sdk-kit/src/rsapi.rs:399-515`). Until upstream
documents a broader guarantee, permit only one active sync operation per synced
database. The safe Zig `SyncDatabase` enforces that single-operation rule and
rejects teardown with a live operation, checked-out I/O item, or adopted
connection. Never resume, inspect, extract, or deinit the same operation
concurrently.

Checkpoint and apply activate a gate that makes local connection prepare/step/
execute/row access return `BUSY`; apply also consumes its Changes before work
begins (`sync/sdk-kit/src/rsapi.rs:440-456`, `492-515`; base `rsapi.rs:529-552`).
Serialize sync mutation with local queries in the high-level wrapper.

### Operation state and result ownership

Every `open/create/connect/stats/checkpoint/push/wait/apply` call returns `OK` plus
a newly owned Operation. Creation itself does not perform the work. Repeatedly:

1. Call `turso_sync_operation_resume`.
2. On `IO`, drain queued IO items, complete each, run IO callbacks, and resume.
3. On `DONE`, inspect/extract the expected result and deinit the Operation.
4. On error, copy/free the error message and deinit the Operation.

Resume is repeatable after completion and returns the same final `DONE` or error
(`sync/sdk-kit/src/turso_async_operation.rs:178-223`). Result kind is `NONE` both
before completion and for a completed void operation, so it is not a completion
test.

The safe Zig wrapper exposes typed `Operation(void|Connection|?Changes|Stats)`
owners. It allows one result extraction after `DONE`, copies Stats revision
bytes, transfers Connections into the base safe owner, and releases an operation
only after result extraction or terminal error. It deliberately rejects
in-progress teardown because the pinned ABI does not prove cancellation
convergence.

- Connection and Changes extraction are destructive, one-shot transfers. A
  second extraction returns `MISUSE: operation has no result`. The extracted
  connection must be `turso_connection_deinit`ed.
- Empty fetched Changes extract as null with `OK`; non-empty Changes must either
  be passed once to apply or deinited once.
- `apply_changes` consumes non-null Changes immediately, even if creating or
  running the operation later fails. Never deinit or reuse Changes after the call
  ([`turso_sync.h:238-253`](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/sync/sdk-kit/turso_sync.h#L238-L253)).
- Stats extraction is non-consuming and may be repeated while the Operation
  remains alive. Its revision slice is borrowed from the Operation and expires
  at operation deinit; copy it first
  ([`turso_sync.h:82-95`](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/sync/sdk-kit/turso_sync.h#L82-L95),
  `sync/sdk-kit/src/turso_async_operation.rs:107-140`).

### IO item ownership and completion

`io_take_item` returns `OK` with either a newly owned item or null when the queue
is empty. All request/header/path/body/content slices borrow from that item and
expire at item deinit (`sync/sdk-kit/src/sync_engine_io.rs:10-100`, `222-259`).

- HTTP: transport must combine optional base URL, method, path, headers, and body.
  The C config has no auth-token field; the transport layer must inject/refresh
  authorization without logging secrets.
- Full read: file-not-found is an empty successful result, per the header.
- Full write: completion means atomic replace semantics, normally temp write,
  fsync, and rename.
- For HTTP, set a valid status before `done`; push response chunks in order.
  The ABI accepts `int32_t`, but implementation truncates through `u32` to `u16`
  (`sync/sdk-kit/src/capi.rs:402-413`, `sync_engine_io.rs:189-209`). Reject negative
  or greater-than-65535 statuses in Zig.
- `poison` copies a UTF-8 transport error and causes later resume to fail.
  `push_buffer` copies bytes. `done` is separate and required.
- The item can be deinited after its request data has been copied and completion
  has been submitted; completion state is shared with the engine. Call
  `turso_sync_database_io_step_callbacks` after completing queued IO and before
  assuming progress. The upstream C test demonstrates the minimal cycle at
  `sync/sdk-kit/src/capi.rs:529-592`.

The Zig `sync.run` driver drains each round through a borrowed caller-owned
transport and guarantees that a checked-out item is completed or poisoned and
then deinited before stepping callbacks. `StandardTransport` borrows the
caller's allocator, `std.Io`, `std.http.Client`, and filesystem root. It requires
HTTPS by default, does not follow redirects, validates static and per-request
provider authorization through the same header boundary, and uses fixed poison
categories so request headers, authorization values, provider errors, response
bodies, and file paths do not enter diagnostics. Provider results are
synchronous caller-owned borrows; no token storage is retained.

Standard full-file requests are confined lexically to normalized, non-empty,
root-relative `/` paths. Absolute paths, dot/parent/empty components,
backslashes, NUL, and Windows drive prefixes are rejected. Full writes use a
synchronized same-directory atomic replacement and missing full reads return an
empty success. This is not portable symlink confinement: the caller must trust
the root tree and prevent untrusted symlink mutation.

### Sync configuration validation

The wrapper sets base and sync paths from one `LocalConfig.path`; upstream
accepts two path fields and does not validate equality. Zig uses unsigned
bounded fields for `long_poll_timeout_ms`, `reserved_bytes`, and prefix values
before C because the implementation casts non-zero signed values to unsigned
sizes (`sync/sdk-kit/src/rsapi.rs:50-126`). Prefix and query partial-bootstrap
strategies are a tagged union and therefore mutually exclusive. Partial sync
and logical MVCC pull remain explicit opt-ins.

Partial bootstrap selects sparse persistent I/O only on Linux. In the pinned
SDK Kit, non-Linux targets fall back to `PlatformIO`, whose files do not provide
the hole-detection contract required by lazy partial storage. This can reach a
panic during page access ([tursodatabase/turso#7841](https://github.com/tursodatabase/turso/issues/7841));
the proposed upstream work remains unreleased
([tursodatabase/turso#7843](https://github.com/tursodatabase/turso/pull/7843)).
The safe Zig configuration therefore rejects non-Linux file-backed partial
bootstrap before allocation or native construction. The exact `:memory:` path
uses `MemoryIO` and remains permitted.

## Known discrepancies and upstream gaps

Priority is impact on a production Zig interface.

| Priority | Finding | Required action |
| --- | --- | --- |
| P0 | `remote_encryption_cipher` is in `turso_sync.h:127-130` but `TursoDatabaseSyncConfig::from_capi` never reads it and engine options carry only the key (`sync/sdk-kit/src/rsapi.rs:50-126`, `243-260`). | The safe Zig config omits selectable remote cipher and tests that the field remains null. Seek upstream fix/clarification before advertising it. |
| P0 | Caller-driven base database open can return `IO`, but no database IO driver exists in `turso.h`. | Force blocking base open (`async_io = 0`) in the safe API. Keep async milestone upstream-blocked. |
| P0 | Sync transform/mutation callback paths contain `todo!()` and `use_transform` is hard-coded false (`sync_engine_io.rs:143-174`, `310-316`; `rsapi.rs:243-260`). | The safe Zig module exposes no transform callbacks; enabling this internally would panic across FFI. |
| P0 | File-backed partial bootstrap uses sparse I/O only on Linux; the non-Linux fallback lacks the required hole-detection behavior ([#7841](https://github.com/tursodatabase/turso/issues/7841)). | Reject non-Linux file-backed partial bootstrap before calling C. Keep `:memory:` available and revisit only after a released upstream fix. |
| P0 | The SDK Kit README C example uses removed/nonexistent types and functions such as `turso_status_t`, `turso_database_create`, result structs, `turso_statement_bind_named`, and `turso_statement_row_value` (`sdk-kit/README.md:72-192`). | Never copy the README C example. Compile examples against the pinned headers. |
| P1 | The header says Connection and Statement are exclusive and forbids close/deinit while calls are active; internal guards cover only some overlap. | Encode exclusivity in safe Zig types and test deterministic sequential rejection. Never race raw same-handle calls or teardown outside the C contract. |
| P1 | Sync database concurrency is under-documented; implementation and Go wrapper serialize operations. | The safe Zig wrapper permits one active operation per sync database until upstream publishes a stronger contract. |
| P1 | Checked-in `bindings.rs` files are manually generated and layout tests are disabled by both bindgen scripts. | Add Zig `@sizeOf`, `@alignOf`, `@offsetOf`, enum-value, function-signature, and exported-symbol drift tests. |
| P1 | C positional binds return status only, losing their native message. Sentinel getters also collapse invalid state and valid zero/null values. | Prevalidate in Zig and preserve a precise wrapper error; do not invent a native message. |
| P1 | Rust API exposes connection interrupt/query-timeout methods, but `turso.h` does not (`sdk-kit/src/rsapi.rs:931-950`). | Omit from safe Zig API or propose upstream C additions; do not bind Rust symbols. |
| P1 | No explicit C ABI revision exists; only crate version is exported. | Require exact `turso_version()` match by default and compare header/symbol manifests on upgrade. |
| P2 | `turso_setup` is process-global/one-shot but its header only says “Setup global database info.” | Make setup idempotent in Zig and document that later filter changes do not take effect. |
| P2 | Unknown experimental feature strings are silently ignored. | Expose every pinned token as a typed flag; keep unknown values only behind validated `unchecked_extra` and make the absence of an upstream effect explicit. |
| P2 | Sync has no auth-token configuration field; transport owns authorization. | Authorization is an explicit caller-owned transport option; the standard driver and tests keep it out of diagnostics. |
