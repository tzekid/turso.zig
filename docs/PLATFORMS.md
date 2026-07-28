# Platform boundaries

This project calls a target supported only after the exact public package has
been linked and executed target-natively. Accepting a Zig target triple,
compiling declarations, or cross-building a native library is useful evidence,
but is not by itself a support claim.

## Current scope

| Target | Status | Evidence boundary |
| --- | --- | --- |
| `x86_64-unknown-linux-gnu` | supported | Base and sync, static and dynamic, native suites and extracted-package consumers |
| `aarch64-unknown-linux-gnu` | supported | Base and sync, static and dynamic, target-native hosted execution |
| `x86_64-unknown-linux-musl` | supported | Base and sync, static and dynamic, Alpine 3.22/musl 1.2.5 native package consumers |
| `aarch64-unknown-linux-musl` | supported | Base and sync, static and dynamic, Alpine 3.22/musl 1.2.5 target-native hosted execution |
| `x86_64-apple-darwin` | supported | Base and sync, static and dynamic, target-native hosted execution |
| `aarch64-apple-darwin` | supported | Base and sync, static and dynamic, target-native hosted execution |
| `x86_64-pc-windows-msvc` | supported | Base and sync, static and dynamic, target-native hosted execution |
| `aarch64-pc-windows-msvc` | unclaimed | Build mappings remain, but target-native execution is deferred in [issue #4](https://github.com/tzekid/turso.zig/issues/4) |
| Android | unclaimed | No Zig package assets, device/emulator execution, or platform contract |
| iOS | unclaimed | No Zig XCFramework/package integration, signing contract, or device/simulator execution |
| browser/WASM | unsupported | The SDK Kit C ABI is not a browser storage and event-loop contract |

The release table in the README is the authoritative list of published target
triples. A platform absent from that table should be treated as experimental
even when `-Dnative=system` can consume a caller-supplied library.

## Source and system native libraries

Source mode infers Rust targets only for the explicit desktop and musl triples
represented in `build.zig`. Cross compilation is rejected by default because
Cargo also needs a matching linker, sysroot, and target-specific native
dependencies.
`-Drust-target` plus `-Dallow-source-cross=true` is an explicit escape hatch for
an externally configured toolchain, not a support claim.

System mode is intentionally less restrictive. The raw declarations and safe
API compile for `aarch64-linux-android` and `aarch64-ios` when native linking is
left to the application. This keeps future mobile integration possible without
pretending that an unexecuted binary is usable.

Pinned Turso v0.7.1 supplies stronger architectural evidence: its
[.NET](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/.github/workflows/dotnet-publish.yml)
and
[React Native](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/bindings/react-native/Makefile)
build paths compile the same base or sync SDK Kit C ABI for Android, and for
iOS device and simulator targets. Those projects also own the work this
repository does not yet have: Android native-library packaging, iOS frameworks
and install names, code signing, minimum OS/API declarations, and
application-level test runners.

Promoting either mobile platform requires a deliberately scoped contribution
that provides:

- target-native base and sync execution on the architectures being claimed;
- a documented minimum Android API or iOS deployment version;
- package installation through the platform's normal application build;
- exact native dependencies, architecture, headers, notices, and ABI checks;
- device and simulator/emulator smoke tests for database persistence;
- a tested transport choice for sync, including secure credential handling;
- explicit VFS, extension-loading, encryption, and partial-bootstrap behavior;
  and
- maintainable artifact signing and hosted-runner ownership.

File-backed partial bootstrap remains Linux-only regardless of mobile
packaging. The caller-supplied sync transport interface can host a
platform-specific implementation; `StandardTransport` is not claimed on a
platform until its `std.http` and filesystem behavior have been executed
there.

## Why browser/WASM is different

The official JavaScript browser package does not demonstrate that the native C
SDK Kit can simply be linked into a Zig WASM build. In pinned v0.7.1 it builds
the
[Rust/Node binding](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/bindings/javascript/packages/wasm/package.json)
for `wasm32-wasip1-threads`, implements a
[browser-specific Rust `IO` backend](https://github.com/tursodatabase/turso/blob/4a88feb7caef869c16f6215b6dc51eafd5b3e54e/bindings/javascript/src/browser.rs),
and supplies JavaScript worker imports that bridge database I/O to OPFS.
Browser tests then exercise that complete runtime.

The current Zig package instead expects a native SDK Kit library and a
synchronous C call boundary. A usable browser target would first need:

- an upstream-supported WASM export/driver contract;
- worker or event-loop integration that cannot deadlock the browser main
  thread;
- OPFS registration, completion, durability, and error semantics;
- browser HTTP/sync transport integration;
- packaging for the WASM module and its JavaScript host imports; and
- real browser execution tests.

Until those pieces exist, `wasm32-wasi` build-graph configuration or a
compile-only artifact would be misleading and is not published.
