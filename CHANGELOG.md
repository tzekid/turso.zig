# Changelog

All notable changes to this project are documented here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) while its public API
is pre-1.0.

## [Unreleased]

### Changed

- Updated the pinned Turso SDK Kit source to v0.7.1; the audited base and sync
  C header bodies and exported symbol surfaces are unchanged from v0.7.0.
- Scoped sync-operation recovery state to each heap-stable `SyncDatabase`
  instead of a process-global registry and spinlock.
- Restricted standard-transport HTTP field names to RFC token characters and
  clarified that plaintext HTTP requires explicit `allow_http` opt-in.
- Rejected file-backed partial bootstrap outside Linux before native
  construction, while retaining portable in-memory partial bootstrap.

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
- Target-native CI on Linux, macOS, and Windows for x86_64 and aarch64, plus
  ABI probes, ownership/fault tests, soak tests, and a local-server sync
  round trip.

### Security

- Runtime rejection of mismatched pre-1.0 SDK Kit versions.
- Extension loading disabled by default, credential redaction, strict sync path
  validation, and explicit borrowed-value lifetime checks.

[Unreleased]: https://github.com/tzekid/turso.zig/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/tzekid/turso.zig/releases/tag/v0.1.0
