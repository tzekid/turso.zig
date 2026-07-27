# Managed callbacks and native extensions

The safe managed-callback API registers Zig scalar functions, aggregate
functions, and collations on one `Connection`. It wraps the pinned Turso SDK Kit
C ABI; callback code is still synchronous native code executing inside the SQL
virtual machine.

## Threading and reentrancy

`Connection`, `Statement`, and `Rows` are exclusive-use values. Under supported
safe API use, one connection cannot execute two callbacks concurrently because
it cannot execute two statements concurrently. A callback runs on the thread
that is currently executing that connection's statement, which need not be the
thread that originally registered it. Callbacks on separate connections can run
concurrently, and their contexts can refer to the same application state, so
shared external state still needs application-level synchronization.

The connection already has an active statement operation while a callback is
running. Do not call back into that same connection, its transaction, or its
current statement. Safe reentrant attempts fail with `error.InvalidState`; raw
native reentrancy is outside the supported contract. Keep callbacks bounded and
do not wait for work that itself needs the invoking connection.

## Callback contracts

Callback arguments are `[]const Value` borrowed only until that callback
returns. Nested TEXT and BLOB slices point into native values owned by Turso.
They must not be saved in a context, aggregate state, global, task, or queue. Copy
a retained value with `Value.toOwned` while the callback is active.

Scalar and aggregate-step callbacks may safely return a `Value` whose TEXT or
BLOB slice points into the current arguments, registration context, or aggregate
state. Before the trampoline returns to C, it copies the payload into a separate
result allocation. This does not make the original callback arguments retainable.
Collation byte slices are valid UTF-8 borrowed only for the comparison call and
must never be retained.

Callbacks use the closed `CallbackError` error set. The trampoline catches every
callback error and returns a Turso extension error value:

| `CallbackError` | Turso extension result |
| --- | --- |
| `OutOfMemory` | `OOM` |
| `InvalidArguments` | `INVALID_ARGS` |
| `Corrupt` | `CORRUPT` |
| `NotFound` | `NOT_FOUND` |
| `AlreadyExists` | `ALREADY_EXISTS` |
| `PermissionDenied` | `PERMISSION_DENIED` |
| `Aborted` | `ABORTED` |
| `OutOfRange` | `OUT_OF_RANGE` |
| `Unimplemented` | `UNIMPLEMENTED` |
| `Internal` | `INTERNAL` |
| `Unavailable` | `UNAVAILABLE` |
| `Custom` | `CUSTOM_ERROR` |
| `EndOfFile` | `EOF` |
| `ReadOnly` | `READ_ONLY` |
| `Interrupt` | `INTERRUPT` |
| `Busy` | `BUSY` |
| `ConstraintViolation` | `CONSTRAINT_VIOLATION` |

The error name becomes the SQL error message when allocation succeeds. If even
the error payload cannot be allocated, the trampoline returns an allocation-free
`OOM` value. A Zig error union never crosses the C ABI.

Zig panics cannot be caught portably at a C boundary. Every callback and optional
context/state deinitializer **must not panic**, execute `unreachable`, throw an
uncaught error, or otherwise unwind. Convert expected failures to
`CallbackError`. Violating this rule can abort or corrupt the process; it is not
converted into a database error.

## Registration and result ownership

`ScalarFunctionOptions`, `AggregateFunctionOptions`, and `CollationOptions` are
moved into their registration call. The registration context is owned by the
wrapper from call entry. If validation, allocation, or native registration
fails, the wrapper invokes `context_deinit` and frees its registration box. On
success, native Turso owns that box and eventually invokes the context
destructor exactly once.

Replacing a function or collation removes the old registry entry. Explicit
`unregisterFunction` and `unregisterCollation` remove it without installing a
replacement. The old context is destroyed only after the last native reference
is released. Turso's prepared programs can retain a resolved function or
collation across registry replacement/unregister. The safe wrapper prevents a
registry mutation while any `Statement` or `Rows` value is live on that
connection, so deinitialize those values first. Raw callers must account for the
native retention themselves. Any remaining registrations are destroyed during
connection teardown.

For INTEGER, FLOAT, and NULL results, there is no nested allocation. For TEXT,
BLOB, and callback-error results, the trampoline allocates a result box holding
the allocator, descriptor, and copied payload. Turso copies the result and then
calls the registered value destructor. That destructor frees the payload and its
matching box exactly once. Context and result allocations are separate ownership
categories and must never alias.

## Aggregate state

An aggregate registration has one registration context plus one independently
owned state box per aggregate group. The zero-row aggregate path also runs init
and final with its own state. A successful init stores the user `State`; an init
error stores only the caught `CallbackError`, so no uninitialized user state is
destroyed.

`step` borrows the state and arguments. `final` borrows the state and returns a
result; it does not consume or free the state. Turso invokes the aggregate
destructor after normal finalization and also when a step error aborts aggregate
execution. `state_deinit` therefore owns state cleanup on every terminal path
and runs exactly once for every successfully initialized state. It must not free
the registration context. Replacement and unregister affect the registration
context, not already-created group states retained by an executing program.

At the pinned upstream revision, a sibling aggregate can be skipped by native
destruction when another aggregate in the same program errors. The safe wrapper
maintains a connection-scoped intrusive tracker as a compatibility guard. A
normal native aggregate destructor removes its state from the tracker. After a
successful native reset/finalize, or after native statement deinit, the wrapper
destroys only states still present. Cleanup never runs while native code can
legitimately dereference the tracked pointer. This guard applies only through
the safe Statement/Rows lifecycle; raw ABI users inherit the upstream behavior.

## Loading native extensions

Native extensions execute trusted machine code inside the application process.
Treat loading one like loading a dynamic library, not like reading data. Use
allowlisted absolute paths, pin and verify the extension artifact, match the
target ABI and Turso SDK revision, and never accept an untrusted database value
or request parameter as an extension path.

SQL `load_extension()` is disabled by default per connection.
`enableLoadExtension(true)` opts that SQL function in; disable it again when a
narrow loading window ends. The explicit `loadExtension(path)` method is already
an explicit trusted-code action and, matching the pinned native implementation,
bypasses the SQL opt-in flag. A successfully loaded native library can keep
process-wide state and is not a sandbox. Load failures are returned through the
normal Turso status and `Diagnostics` path.
