# Contributing

Thank you for helping improve the Zig bindings. This repository tracks a
pre-1.0 native ABI, so seemingly small changes can affect ownership, binary
compatibility, or every supported platform.

Participation is governed by [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Before opening a change

- Use GitHub Discussions or an issue for design questions that would materially
  change the public API.
- Search existing issues before reporting a defect or feature request.
- Report suspected vulnerabilities through the private process in
  [SECURITY.md](SECURITY.md), not a public issue.
- Keep pull requests focused. Separate refactors from behavioral changes where
  practical.

The supported development baseline is Zig 0.16.0, Rust 1.88, and a C toolchain.
The default build compiles the pinned Turso SDK Kit from source.

## Development checks

Run the checks relevant to the change, with these as the normal baseline:

```sh
zig fmt --check .
zig build test
zig build examples
zig build docs
zig build test-sync-abi -Dsync=true
```

Shell changes must also pass:

```sh
bash -n tools/*.sh tests/release-package*.sh
shellcheck tools/*.sh tests/release-package*.sh
```

Add a focused regression test for behavior changes. See
[docs/TEST_MATRIX.md](docs/TEST_MATRIX.md) for platform, fault-injection,
consumer, soak, and packaging gates.

## ABI and ownership changes

Read [docs/UPSTREAM_ABI.md](docs/UPSTREAM_ABI.md) before editing native
lifecycle code. Preserve these boundaries:

- bind only the supported C ABI, never Rust symbols or layouts;
- keep raw declarations separate from the safe public API;
- document one owner for every allocation and native handle;
- release child handles before their parents;
- copy native errors before freeing them on every status path;
- never allow Zig errors or panics to cross a C callback;
- treat row text and blobs as borrowed until the next statement operation; and
- keep extension loading off and secret values out of diagnostics by default.

An upstream SDK update must follow
[docs/UPDATING_TURSO.md](docs/UPDATING_TURSO.md) and include reviewed header,
symbol-manifest, runtime-version, ownership, and provenance changes together.

## Pull requests

Use an imperative, lowercase commit summary, optionally with a short scope:

```text
rows: add checked owned decoding
build: update the pinned SDK Kit
```

In the pull request:

- explain the user-visible outcome and motivation;
- call out ABI, ownership, security, or compatibility tradeoffs;
- list the exact checks run;
- update public documentation and `CHANGELOG.md` when appropriate; and
- disclose meaningful automated or AI assistance, including what it produced
  and how the result was reviewed.

Review your own diff before requesting review. A change is not complete while a
supported CI lane is failing or skipped without an explicit scope decision.
