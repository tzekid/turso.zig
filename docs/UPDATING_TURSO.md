# Updating the pinned Turso SDK Kit

Treat every Turso update as an ABI migration. The SDK Kit is pre-1.0, so an
unchanged function name does not guarantee compatible layout, ownership,
status, or behavior.

## 1. Establish immutable provenance

Use a separate Turso checkout. On `master`, resolve `main` once and immediately
freeze the resulting full commit; for a stable release, select an annotated
release tag:

```sh
git -C /path/to/turso fetch --tags origin main
git -C /path/to/turso rev-parse 'origin/main^{commit}' # development
git -C /path/to/turso rev-parse '<tag>^{tag}'           # stable release
git -C /path/to/turso rev-parse '<tag>^{commit}'        # stable release
git -C /path/to/turso show -s --format='%ct %cI' '<commit>'
```

Record the discovery channel, immutable commit, source timestamp,
commit-addressed archive URL, and Zig package hash. Stable releases additionally
record and verify the annotated tag object and peeled commit. Never invent tag
provenance for a development commit. Review the full upstream diff from the
previous promoted commit.

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

1. Update the commit-addressed source URL and Zig package hash in
   `build.zig.zon`.
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

Run the complete matrix in [TEST_MATRIX.md](TEST_MATRIX.md): required
source/static checks on the supported native targets, scheduled dynamic/system
and feature coverage, clean consumers, and the extended fault and soak gates.
Build a matching local `tursodb` and run the sync E2E gate.

Capture native static link requirements, dynamic dependencies, minimum libc/OS
evidence, tool versions, checksums, and installed runtime lookup separately for
each target.

## 6. Promote development or release intentionally

Development promotion updates `master` without changing the binding version or
publishing assets. Update `CHANGELOG.md` even when downstream Zig source remains
compatible and run the target manifest, ABI, behavior, and hosted gates.

Stable publication is a separate compatibility event. It first replaces
development Zig and Turso inputs with stable versions and real tag provenance,
then runs deterministic package assembly and extracted-consumer smoke tests.
Publish only after the release commit is green and the annotated tags point to
the exact audited commits.
