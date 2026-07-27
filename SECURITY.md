# Security policy and ownership guidance

## Reporting a vulnerability

Please use GitHub's private
[security advisory form](https://github.com/tzekid/turso.zig/security/advisories/new)
for suspected vulnerabilities. Do not open a public issue for secrets,
memory-safety defects, path escapes, or vulnerabilities that have not yet been
coordinated.

Supported security fixes target the latest tagged release and the default
branch. Reports should include the affected version, platform, native linkage
mode, reproduction steps, and impact. Never include production credentials,
encryption keys, or private database contents.

## Native library trust

`turso.zig` calls Turso through its supported C ABI. The native library executes
inside the application process with the application's privileges. Pin the exact
Turso release recorded by this package, verify release artifacts and checksums,
and do not substitute an untrusted system library. The safe database open path
checks the runtime version, but version equality is not artifact authenticity.

Native extension loading is a code-execution boundary. Keep it disabled unless
the application deliberately loads a trusted, authenticated library from a path
an attacker cannot replace.

## Encryption at rest

Turso's local encryption support is experimental and must be enabled in the
native build. `Database.open` automatically enables the corresponding database
feature when `EncryptionOptions` is supplied.

- Generate keys with an operating-system CSPRNG or a managed secret service.
- Match the key length to the selected cipher. The API expects lowercase or
  uppercase hexadecimal bytes, not a password.
- Keep keys out of source control, command lines, environment dumps, crash
  reports, telemetry, SQL, and log fields.
- Fetch the key from a secret manager as late as possible. The wrapper wipes its
  temporary C-string copy after the native constructor returns; it cannot wipe
  the caller's original slice. If the caller owns a mutable key buffer, wipe it
  after `Database.open` has copied it.
- Losing the key makes the database unrecoverable. Back up keys separately with
  access control and rotation procedures appropriate to the application.
- Protect the database directory and backups with restrictive filesystem
  permissions. Encryption does not hide filenames, access patterns, process
  memory, or data returned to the application.

Opening a database with a wrong key may create a native handle and fail only when
the first encrypted page is accessed. Test key validity with a real query before
declaring the database healthy. Never include a key in an error message; the
security integration test verifies that validation and wrong-key diagnostics do
not contain either tested key.

## Diagnostics and logging

`Diagnostics` has a fixed-size allocation-free buffer. It is safe to preserve an
error during allocator failure, but its text can still include SQL, paths, table
names, or values emitted by the native engine. Treat diagnostics as sensitive
operational data and redact them before sending them outside the trust boundary.

`setup` configures a process-global logger once. Configure it before starting
worker threads. A logger callback:

- can run on arbitrary Turso threads;
- receives message, target, and file slices borrowed only for that callback;
- must copy any retained bytes before returning;
- must synchronize shared state;
- must never panic or let a Zig error cross the C callback boundary; and
- should redact SQL and application data before persistence.

A second `setup` call is rejected because replacing process-global callback
state would make ownership and filtering ambiguous.

## Handle and row ownership

The required lifetime order is:

```text
Database > Connection > Transaction > Statement/Rows > Row/ValueRef
```

Deinitialize children before parents. Public handle structs are move-only by
convention; do not intentionally duplicate them. Heap-stable internal controls
make relocation safe and detect sequential stale copies, but concurrent access
through copied values remains outside the contract.

`Row`, borrowed TEXT, and borrowed BLOB are valid only until the next rows
operation. The wrapper checks a generation before native row access, so stale
use returns `InvalidState`, but applications should still copy data they retain.
Use `toOwned` or allocator-aware typed decoding for that copy.

Use explicit cleanup when the outcome matters:

- `Rows.finish` drains/finalizes and reports native errors.
- `Rows.cancel` explicitly aborts pending iteration and reports cleanup errors.
- `Rows.deinit` performs best-effort cancellation and cannot report failure.
- `Transaction.commit` and `Transaction.rollback` report their outcomes.
- `Transaction.deinit` rolls back an active transaction best-effort and can
  poison the connection if native rollback fails.

Do not destroy a connection with live rows, statements, or a transaction.

## SQL and concurrency

Use bound parameters for data. Parameter binding does not make identifiers or
SQL fragments safe; allow-list any dynamic table, column, collation, or ordering
tokens before constructing SQL.

A Connection and its active Statement/Rows are exclusive and not thread-safe.
Use independent connections for concurrent work. The wrapper never
automatically retries `Busy` or `BusySnapshot`: retrying a transaction can repeat
external side effects, so the application must own that policy.

If a Database or any derived Connections may be used concurrently, the allocator
originally passed to `Database.open` must be thread-safe for their full lifetime.
All wrapper allocations and deallocations are in scope—including queries,
metadata, registration replacement/unregister, callbacks, and deinit—not only
concurrent calls to `Database.connect`. This requirement includes custom
allocators that wrap otherwise thread-safe storage.

## Cloud sync transport

Cloud sync is opt-in with `-Dsync=true`. The sync wrapper does not own a hidden
HTTP client, credential store, runtime, or filesystem root. `sync.run` borrows
the caller's transport, and `StandardTransport` in turn borrows its allocator,
`std.Io`, `std.http.Client`, and `root_dir`; all must remain valid until the
operation finishes.

Keep authorization outside `SyncConfig`. Pass it as the separate transport
authorization header, obtain it from a secret manager or similarly protected
source, and rotate it in caller code. The standard adapter does not follow
redirects, so it never forwards authorization across origins. HTTPS is required
unless the caller explicitly sets `allow_http` for a trusted development
environment. Header validation rejects CR/LF injection. Transport failures are
reported to the native operation as fixed categories and do not include request
headers, authorization values, response bodies, or filesystem paths.

`StandardTransport.root_dir` is only a lexical filesystem boundary. It rejects
absolute paths, `.` and `..`, empty components, backslashes, NUL, and Windows
drive prefixes, and performs full writes through a synchronized same-directory
atomic replacement. It does not provide portable symlink confinement. Use a
trusted directory tree that untrusted processes cannot mutate; a pre-existing
or replaced symlink can otherwise resolve outside the apparent root.

One sync database owns at most one live operation. Every I/O item must be
completed or poisoned and deinited before resuming, and extracted connections
must be deinited before the sync database. Do not expose remote cipher selection
or transform callbacks: the pinned upstream C implementation does not safely
support those header surfaces. Live Cloud behavior has not been proven by the
credential-free local suite.
