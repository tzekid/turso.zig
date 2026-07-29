# Changelog

All notable changes to this project are documented here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) while its public API
is pre-1.0.

## [Unreleased]

### Added

- Added structured parameterized batches with explicit atomic/non-atomic
  transaction policy, partial failure reports, per-entry change/row-ID
  metadata, and bounded allocator-owned row materialization.
- Added common sync workflows for typed void/Connection operations, conditional
  pull/apply, and explicit push-then-pull sequencing while retaining the
  low-level driver.
- Added a caller-owned authorization provider resolved independently for every
  sync HTTP item, with static-header compatibility, explicit null injection,
  and fixed secret-free failure categories.
- Added typed `mvcc_passive_checkpoint` feature configuration and complete
  deterministic rendering for every feature parsed by SDK Kit v0.7.1.
- Added target-native Alpine 3.22 release packages for x86_64 and aarch64
  Linux musl, covering base/sync SDK variants with static/dynamic linkage.
- Added focused examples for persistent file databases, every SQL value kind
  and owned row copies, diagnostics, busy timeouts, and statement metadata.

### Changed

- Made prepared SELECT statements reusable through `Statement.query` and
  `queryParams`, with heap-stable Rows leases and multiple idle statements per
  Connection while preserving one active execution.
- Updated the pinned Turso SDK Kit source to v0.7.1; the audited base and sync
  C header bodies and exported symbol surfaces are unchanged from v0.7.0.
- Scoped sync-operation recovery state to each heap-stable `SyncDatabase`
  instead of a process-global registry and spinlock.
- Restricted standard-transport HTTP field names to RFC token characters and
  clarified that plaintext HTTP requires explicit `allow_http` opt-in.
- Rejected file-backed partial bootstrap outside Linux before native
  construction, while retaining portable in-memory partial bootstrap.
- Renamed `FeatureSet.extra` to `unchecked_extra`; unchecked names must now be
  unique valid UTF-8 tokens and cannot duplicate any typed feature. Upstream
  may still ignore syntactically accepted unknown names.
- Defined platform support by target-native package execution, documented the
  work needed to promote Android/iOS, and kept browser/WASM explicitly outside
  the native SDK Kit C ABI claim.
- Kept owner-count and active-handle bookkeeping checks fatal in every
  optimization mode, with dedicated Debug and ReleaseFast panic probes.

### Known limitations

- The safe API remains blocking because the pinned C ABI has no complete
  database-level async driver. Query interruption and in-progress sync
  cancellation are also unavailable through that ABI.
- Remote cipher selection and transform callbacks remain omitted until their
  upstream C conversion and callback paths are complete.
- Release targets exclude Windows ARM64 while
  [issue #4](https://github.com/tzekid/turso.zig/issues/4) is open, Android,
  iOS, and browser/WASM. Sync evidence uses a real local `tursodb` server but
  does not claim credentialed Turso Cloud coverage.

## [0.1.0] - 2026-07-27

### Added

- Ownership-safe Zig API for databases, connections, statements, rows,
  transactions, values, diagnostics, scalar and aggregate functions, and
  collations.
- Complete raw declarations for the pinned base and sync SDK Kit C headers.
- Opt-in Cloud sync module with caller-owned HTTP and filesystem transport,
  push, pull/apply, statistics, and checkpoint operations.
- Source and system native-library modes with static and dynamic linkage.
- Local encryption, feature selection, typed row decoding, examples, generated
  API documentation, clean-consumer tests, and deterministic release packages.
- Target-native CI on Linux and macOS for x86_64 and aarch64, and on Windows
  for x86_64, plus ABI probes, ownership/fault tests, soak tests, and a
  local-server sync round trip.

### Security

- Runtime rejection of mismatched pre-1.0 SDK Kit versions.
- Extension loading disabled by default, credential redaction, strict sync path
  validation, and explicit borrowed-value lifetime checks.

[Unreleased]: https://github.com/tzekid/turso.zig/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/tzekid/turso.zig/releases/tag/v0.1.0
