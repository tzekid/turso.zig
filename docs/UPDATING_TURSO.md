# Updating the pinned Turso SDK Kit

Treat every Turso update as an ABI migration. The SDK Kit is pre-1.0, so an
unchanged function name does not guarantee compatible layout, ownership,
status, or behavior.

## 1. Establish immutable provenance

Use a separate Turso checkout and select a release tag rather than a moving
branch:

```sh
git -C /path/to/turso fetch --tags origin
git -C /path/to/turso rev-parse '<tag>^{tag}'
git -C /path/to/turso rev-parse '<tag>^{commit}'
git -C /path/to/turso show -s --format='%ct %cI' '<tag>^{commit}'
```

Record the annotated tag object, peeled source commit, source timestamp, archive
URL, and Zig package hash. Review the full upstream diff from the previous
peeled commit.

## 2. Audit the C boundary first

Review both public SDK Kit surfaces and their implementations:

- `sdk-kit/turso.h`, `sdk-kit/src/capi.rs`, and `sdk-kit/src/rsapi.rs`;
- `sync/sdk-kit/turso_sync.h` and `sync/sdk-kit/src/`;
- generated Rust bindings and bindgen scripts;
- managed function, collation, and aggregate ownership;
- crate features, native library names, target dependencies, and toolchain;
- upstream `LICENSE.md` and `NOTICE.md`.

For each changed declaration, determine input/output ownership, borrowed
lifetime, destructor, threading rule, status behavior, sentinel behavior, and
error-string allocation. Record evidence in [UPSTREAM_ABI.md](UPSTREAM_ABI.md)
before changing the safe wrapper.

## 3. Update package inputs together

In one reviewable change:

1. Update the source tag URL and Zig package hash in `build.zig.zon`.
2. Copy both exact headers into `include/`, retaining their wrapper attribution.
3. Update `src/version.zig`, `src/build_options.zig`, `NOTICE`, the
   `SOURCE_DATE_EPOCH` in `build.zig`, and
   [RELEASING.md](RELEASING.md).
4. Update CI provenance checks and expected runtime-version assertions.
5. Regenerate both sorted symbol candidates and manually review every
   addition, removal, and rename:

   ```sh
   tools/check-abi-symbols.sh --header-only
   tools/check-abi-symbols.sh --sync --header-only
   ```

6. Update target mappings and static dependency closure only from
   target-native evidence.

Keep the dependency lazy so native-independent tests do not fetch or compile
Rust sources.

## 4. Adapt raw and safe layers

`src/raw.zig` and `src/sync/raw.zig` should remain mechanical translations of
the supported C headers. Add compile-time and C-probe-backed assertions for new
layouts, constants, callbacks, and signatures. Then update the safe layers
while preserving:

- exact runtime-version rejection before safe native calls;
- heap-stable parent/child ownership controls;
- native error strings copied and freed on every path;
- borrowed row-value invalidation after the next statement operation;
- explicit finish, cancel, close, commit, and rollback semantics;
- exactly-once callback and aggregate-state destruction;
- full UTF-8 and interior-NUL validation before side effects;
- no Zig errors or panics crossing C callbacks; and
- no implicit transaction retries.

Do not add a private Rust ABI or expose a lifecycle that the C contract cannot
support safely. Document and report upstream gaps instead.

## 5. Rebuild compatibility evidence

The build accepts an explicit checkout so a candidate can be tested without
changing the production pin:

```sh
zig build test-pure -Dturso-source=/path/to/turso
zig build test-abi -Dturso-source=/path/to/turso -j2 --summary all
zig build test-sync-abi \
  -Dsync=true \
  -Dturso-source=/path/to/turso \
  -j2 \
  --summary all
```

Run the complete matrix in [TEST_MATRIX.md](TEST_MATRIX.md), including source
and system modes, static and dynamic linkage, Debug and ReleaseSafe, feature
variants, clean consumers, and native macOS/Windows/aarch64 execution. Build a
matching local `tursodb` and run the sync E2E gate.

Capture native static link requirements, dynamic dependencies, minimum libc/OS
evidence, tool versions, checksums, and installed runtime lookup separately for
each target.

## 6. Release as an intentional compatibility event

Update `CHANGELOG.md` even when downstream Zig source remains compatible. Run
deterministic package assembly and extracted-consumer smoke tests, verify both
upstream notices, and require the full hosted matrix. Publish only after the
release commit is green and the annotated tag points to that exact commit.
