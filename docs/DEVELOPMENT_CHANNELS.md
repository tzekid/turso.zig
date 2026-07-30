# Development target migration specification

Status: implemented on `master`; routine auto-merge remains in the documented
three-cycle shadow period

Applies to: `master`

Stable maintenance branch: `v0.1.1-stable`

Last evidence refresh: 2026-07-30

This specification defines how `master` moves from stable Zig and Turso inputs
to their development channels without sacrificing reproducibility, reviewable
native provenance, supported-platform evidence, or the existing stable line.

The words **must**, **must not**, **should**, and **may** are normative.

## 1. Summary

`master` will target the latest Zig `master` build and Turso `main` commit that
pass this repository's required checks. Channel names are used only to discover
candidates. Every accepted turso.zig commit pins exact immutable inputs.

Zig and Turso remain separate update units after the initial migration. The
migration does not change the package version from `0.1.1`, publish a release,
modify `v0.1.1-stable`, or expand the supported-platform contract.

After the initial migration, scheduled automation will detect new candidates,
classify them, and either prepare a routine update pull request or create a
maintenance issue. Automation must never push directly to `master`, modify a
stable branch, or publish a release.

## 2. Goals

The implementation must:

1. move `master` to an exact Zig development build;
2. move `master` to an exact Turso `main` commit;
3. preserve a reproducible build for every turso.zig commit;
4. retain full upstream source, header, ABI, runtime, and toolchain provenance;
5. keep Zig and Turso updates independently reviewable and revertible;
6. make required CI exercise the exact promoted inputs;
7. detect newer channel revisions programmatically;
8. distinguish routine updates from maintenance-requiring changes;
9. notify the maintainer only when action is useful; and
10. keep stable releases gated on stable Zig and Turso versions.

## 3. Non-goals

This migration does not:

- change the turso.zig package version from `0.1.1`;
- create or move a release tag;
- change `v0.1.1-stable`;
- promise source compatibility between arbitrary Zig development builds;
- promise ABI compatibility between arbitrary Turso `main` commits;
- add macOS Intel, musl, mobile, browser, or Windows ARM64 release support;
- make prerelease inputs eligible for stable publication;
- add a private Rust ABI to work around an incomplete C contract;
- automatically merge a change that modifies wrapper source or public ABI; or
- claim that passing tests prove the absence of semantic upstream changes.

## 4. Locked decisions

### 4.1 Branches and versions

- `master` is the rolling development branch.
- `v0.1.1-stable` remains on Zig `0.16.0` and Turso `v0.7.1`.
- The current package version remains `0.1.1` on `master`.
- Nightly dependency updates do not change the package version.
- A future minor version requires a separate deliberate release decision.
- Existing release tags are immutable.

The stable branch was corrected at
`ad1f1c0141407789db320bd6a9c9b68832d788f5`. The published `v0.1.0`
tag remains at `43d0b9d48eaf873453ee6882b301c2421850ade3`.

### 4.2 Candidate isolation

- One pull request may update Zig or Turso, never both.
- A candidate is resolved once at the start of its pull request.
- If the upstream channel moves during implementation, the pull request remains
  on its recorded candidate.
- A newer revision is handled by a later update.
- Zig migration lands before Turso migration so Turso is tested with the
  intended development compiler.

### 4.3 Reproducibility

- Required CI must never use a floating Zig `master` installer value.
- `build.zig.zon` must never use a moving Turso `main` archive URL.
- Zig is pinned by its complete development version.
- Turso is pinned by its complete 40-character commit ID and archive hash.
- Checksums are verified before a downloaded tool or source archive is used.
- Vendored headers name the exact Turso commit from which they were copied.

### 4.4 Automation authority

Automation may:

- resolve candidates;
- run tests and produce evidence;
- create or update an automation branch;
- open a draft pull request;
- enable auto-merge for a provenance-only routine update after all gates pass;
- open or update a deduplicated maintenance issue; and
- attach logs, diffs, summaries, and reproduction commands.

Automation must not:

- push directly to `master`;
- push to or rewrite a stable branch;
- move or create a release tag;
- publish a GitHub Release;
- auto-merge wrapper source, header declaration, symbol, layout, ownership, or
  behavior changes; or
- expose credentials to code fetched from an upstream candidate.

### 4.5 Notification channel

GitHub is the source of notification truth. Maintenance issues are assigned to
the repository owner and GitHub routes notifications to the owner's configured
Fastmail address. The address itself and any mail credentials must not be
committed to the repository.

The initial implementation does not require SMTP, a transactional email
service, or a mailbox connector.

## 5. Baseline

At the start of this specification, `master` has:

| Item | Baseline |
| --- | --- |
| turso.zig | `0.1.1` |
| Zig | `0.16.0` |
| Rust | `1.88` |
| Turso runtime/crate | `0.7.1` |
| Turso tag | `v0.7.1` |
| Turso tag object | `31cdceeb07d3b294e5b2f13b03cfdbbf59769b78` |
| Turso source commit | `4a88feb7caef869c16f6215b6dc51eafd5b3e54e` |
| Turso package hash | `N-V-__8AABYTqgLLoRwhKj-QpEwCZuEqg0n62mHiVJuZRQcd` |
| Base header SHA-256 | `14ee49b4f6c00e3f8c3c710b4df1c316ecc0802e1d8b19815d8caab09f2b70cb` |
| Sync header SHA-256 | `38b9dc73fc2fe45c3d86d69ff2ad48b8c99d693a4462514ea50fb876aba6ee35` |
| Source epoch | `1784727869` |

The required supported targets remain those in
[TEST_MATRIX.md](TEST_MATRIX.md) and [PLATFORMS.md](PLATFORMS.md):

- Linux glibc x86_64;
- Linux glibc ARM64;
- macOS ARM64; and
- Windows x86_64 MSVC.

Windows ARM64 remains a non-blocking Tier 3 preview.

## 6. Initial candidate evidence

Candidate values are a discovery snapshot. At implementation kickoff, the
resolver must refresh the channels once and freeze the resulting values in the
corresponding pull request.

### 6.1 Zig candidate

Observed from the official Zig download index on 2026-07-30:

| Item | Value |
| --- | --- |
| Channel | `master` |
| Version | `0.17.0-dev.1509+bb296ab9b` |
| Build date | `2026-07-29` |
| Linux x86_64 archive SHA-256 | `48cc865b8b410ec84eaa97e50c2bd7a657871802ce3aaaf04dd1da2294d4b28a` |
| Linux ARM64 archive SHA-256 | `7f17e09b675cfe39805c5b551b251151f7750b9df8a168538007890c1c00dc8e` |
| macOS ARM64 archive SHA-256 | `24bd83c1d435b8ab6192f58afcc22f4e5252077a938ffbc35eaa4ca97c5be709` |
| Windows x86_64 archive SHA-256 | `a4f537761ca1f5274c9bb0e7da598c6e82205a4ea78f329690a26eade555d7e8` |
| Windows ARM64 archive SHA-256 | `1fa7a2b5f5442628287fead0f7451b8cb93ed2ca5dd6c79f8026fc8ca83580d2` |

The official index is the discovery source:
<https://ziglang.org/download/index.json>.

### 6.2 Known Zig migration failures

A discovery run with `0.17.0-dev.1509+bb296ab9b` found:

- the new formatter rejects asymmetric whitespace around `**` in
  `tests/diagnostics.zig`, `tests/security.zig`, and `tests/production.zig`;
- `src/status.zig` and `src/sync/std_transport.zig` require formatter output;
- `std.Build.pathFromRoot` is no longer available and every use in `build.zig`
  must move to the supported Zig 0.17 path API;
- `std.builtin.OptimizeMode` values used by the build graph have changed naming,
  including the current `.Debug` comparison; and
- `zig build test-pure` stops during build-script compilation before exercising
  project tests.

These are the first reported errors, not a complete migration inventory. The
implementation must rerun after each class of build error is fixed until all
gates compile and execute.

Zig 0.17 development distributions also ship build/package machinery as source.
The first build may compile that machinery and needs more temporary disk and
time than Zig 0.16. CI setup and local instructions must not assume the old
unpacked footprint or first-run latency.

### 6.3 Turso candidate

Observed on 2026-07-30:

| Item | Value |
| --- | --- |
| Channel | `main` |
| Commit | `6e527a75595576790566f3d36560fbe95c5d87a2` |
| Commit timestamp | `2026-07-30T13:47:25Z` |
| Source epoch | `1785419245` |
| Declared workspace version | `0.8.0-pre.2` |
| Archive URL | `https://github.com/tursodatabase/turso/archive/6e527a75595576790566f3d36560fbe95c5d87a2.tar.gz` |
| Zig package hash | `N-V-__8AADSU3gJ2m0iao7tlMOrDWVZW3oJjYQEf7rh-RdUr` |
| Base header SHA-256 | `14ee49b4f6c00e3f8c3c710b4df1c316ecc0802e1d8b19815d8caab09f2b70cb` |
| Sync header SHA-256 | `f9de9cb7eab356e59fd7efdbc02c6a35598588202297535436ecfeaa8ad7bda1` |
| Rust toolchain | `1.88` |

The base header is byte-for-byte unchanged from `v0.7.1`. The sync header
changes only the comment describing `logical_mvcc_pull`: `false` now
auto-detects the remote protocol, while `true` is an escape hatch that forces
MVCC logical-log pulls. No C declaration changed in that observed diff.

The package hash was computed and verified with the promoted Zig development
compiler.

The unchanged declarations do not make this a provenance-only update. Relevant
Rust implementation and workspace changes since `v0.7.1` include async-open
refactors, reset behavior, managed extension APIs, custom column metadata,
feature handling, sync protocol selection, MVCC behavior, and dependency-lock
changes. They require the full behavioral and ownership review in this
specification.

## 7. Machine-readable target manifest

The implementation must add `tools/development-targets.json` as the canonical
automation manifest for promoted development inputs.

Its schema must contain:

```json
{
  "schema": 1,
  "binding_version": "0.1.1",
  "zig": {
    "channel": "master",
    "version": "<exact Zig development version>",
    "date": "<YYYY-MM-DD>",
    "assets": {
      "<supported Zig host name>": {
        "url": "<immutable archive URL>",
        "sha256": "<64 lowercase hex characters>"
      }
    }
  },
  "turso": {
    "channel": "main",
    "declared_version": "<upstream workspace version>",
    "commit": "<40 lowercase hex characters>",
    "commit_timestamp": "<RFC 3339 UTC>",
    "source_date_epoch": 0,
    "archive_url": "<commit-addressed URL>",
    "zig_package_hash": "<Zig package hash>",
    "base_header_sha256": "<64 lowercase hex characters>",
    "sync_header_sha256": "<64 lowercase hex characters>",
    "rust_toolchain": "<exact channel>"
  }
}
```

The manifest does not replace values required by Zig source or
`build.zig.zon`. A consistency checker must verify that all required copies
agree. This avoids generating Zig source during ordinary builds while still
giving automation one structured document to compare.

`tools/check-development-targets.sh` must fail when any of these disagree:

- `tools/development-targets.json`;
- `build.zig.zon`;
- `src/version.zig`;
- `src/build_options.zig`;
- CI and scheduled workflow versions;
- vendored header provenance comments;
- `NOTICE`;
- source epoch settings;
- expected runtime-version tests; and
- public development documentation.

## 8. Provenance model

### 8.1 Zig

The exact development version must appear in:

- `build.zig.zon` as `minimum_zig_version`;
- `src/version.zig`;
- `tests/consumer/build.zig.zon`;
- required and extended workflows;
- the target manifest;
- the README development requirements; and
- evidence emitted by CI.

The formatter and compiler used by required CI must report that exact version.
Scheduled discovery may install literal `master`, but candidate output must
record the resolved version before testing it.

### 8.2 Turso

Development provenance has a commit and channel, not a release tag. The
implementation must not invent a tag object for `main`.

`src/version.zig` must distinguish:

- the upstream runtime version;
- the discovery channel (`main`);
- the immutable commit;
- an optional stable tag; and
- an optional annotated tag object.

Tag fields are absent or null for development commits. Runtime-version
rejection remains exact: the safe API must reject a native SDK Kit that does
not report the promoted Turso workspace version.

`NOTICE` and generated package manifests must describe a development commit
truthfully. Stable release provenance continues to require a real annotated
tag and peeled commit.

## 9. Zig migration workstream

The Zig pull request must perform the following work in order.

### 9.1 Pin and install

1. Resolve the latest official `master` version once.
2. Verify all supported-host asset URLs and SHA-256 values.
3. Record the exact candidate in the target manifest.
4. Update `build.zig.zon`, `src/version.zig`, the consumer fixture, and
   workflows to the same exact version.
5. Ensure setup actions resolve that exact version rather than current
   `master`.
6. Update direct archive downloads to use the immutable URL from the official
   index instead of constructing stable-release paths.

### 9.2 Adapt source and build APIs

1. Apply the Zig 0.17 formatter and review every change.
2. Replace all removed `std.Build.pathFromRoot` calls through one local helper
   using the supported path API.
3. Update optimization-mode enum values and comparisons.
4. Address further build-system, standard-library, compiler, C-import, or test
   failures revealed after those first blockers.
5. Preserve build options, lazy Turso fetching, target selection, source/system
   modes, linkage behavior, installed paths, and public module names.
6. Do not mix unrelated API cleanup into the compiler migration.

### 9.3 Update tooling and CI

Review every Zig assumption in:

- `.github/workflows/ci.yml`;
- `.github/workflows/drift.yml`;
- `.github/workflows/extended.yml`;
- `.github/workflows/release.yml`;
- `.github/workflows/windows-arm-preview.yml`;
- `tools/package-release.sh`;
- `tools/smoke-release.sh`;
- `tests/release-package-musl.sh`;
- consumer fixtures; and
- documentation and badges.

Release tooling must reject development inputs for publication. Development
verification may build source packages, but a prerelease compiler must never
pass the stable-release publication guard.

### 9.4 Zig acceptance gates

The Zig pull request is complete only when:

- `zig fmt --check .` passes with the promoted compiler;
- `zig build test-pure` passes;
- `zig build test-ownership-invariants -Doptimize=ReleaseFast` passes;
- `zig build test` passes against the still-pinned Turso `v0.7.1`;
- examples and API docs pass;
- base and sync ABI gates pass;
- clean consumer builds pass;
- all required supported-platform jobs pass;
- the manually dispatched extended workflow passes; and
- the drift workflow reports the promoted Zig version explicitly.

## 10. Turso migration workstream

The Turso pull request starts only after the Zig migration is green on
`master`.

### 10.1 Freeze provenance

1. Resolve Turso `main` once.
2. record the full commit and commit timestamp;
3. use a commit-addressed archive URL;
4. compute the Zig package hash using the promoted Zig compiler;
5. record the declared workspace version and Rust toolchain;
6. copy both exact public headers;
7. compute header body hashes; and
8. review `LICENSE.md`, `NOTICE.md`, crate features, and native dependencies.

### 10.2 Audit upstream changes

Follow [UPDATING_TURSO.md](UPDATING_TURSO.md) and update it so development
commits are a supported provenance mode.

The review must cover:

- `sdk-kit/turso.h`;
- `sdk-kit/src/capi.rs`;
- `sdk-kit/src/rsapi.rs`;
- `sync/sdk-kit/turso_sync.h`;
- `sync/sdk-kit/src/`;
- binding-generation scripts and generated Rust bindings;
- Cargo workspace and SDK Kit manifests;
- lockfile and Rust toolchain changes;
- runtime-version reporting;
- native library names and exported symbols;
- static native-link requirements;
- feature-name parsing and ordering;
- ownership, borrowed lifetimes, and destructors;
- callback and aggregate-state cleanup;
- statement reset, finish, close, and error behavior;
- database open and async-open internals;
- sync protocol selection and recovery semantics; and
- error allocation, copying, and freeing.

Comment-only header changes still update the vendored header, provenance hash,
and audit record. They do not by themselves require wrapper code changes.

### 10.3 Update wrapper inputs

The Turso migration must update together:

- `build.zig.zon`;
- `build.zig` source epoch and native build assumptions;
- `src/version.zig`;
- `src/build_options.zig`;
- both vendored headers and their provenance comments;
- `NOTICE`;
- expected symbol manifests;
- expected runtime-version tests;
- feature configuration and tests;
- drift tooling;
- source-package manifests and smoke checks;
- `UPSTREAM_ABI.md`;
- `RELEASING.md`;
- API and platform documentation; and
- `CHANGELOG.md`.

Raw declarations must remain mechanical translations of supported C
declarations. Safe wrappers may change only after the corresponding ownership
and behavior evidence is documented.

### 10.4 Turso acceptance gates

The Turso pull request must pass:

- target consistency and provenance checks;
- header and generated-declaration diffs;
- exact base and sync export allowlists;
- C layout, enum, constant, and signature probes;
- runtime-version match and mismatch tests;
- pure, ABI, safe, batch, transaction, callback, failure, durability, and SQL
  corpus suites;
- source and system mode;
- static and dynamic linkage;
- base and sync variants;
- Debug and ReleaseSafe where native state is affected;
- feature variants;
- clean consumers;
- supported target-native CI;
- Valgrind and deterministic disk-fault gates;
- lifecycle and contention soak;
- deterministic source-package assembly and extracted consumer smoke;
- a matching local `tursodb` sync round trip; and
- review of all platform claims against actual target-native evidence.

Credentialed Turso Cloud remains outside the public acceptance contract.

## 11. Required CI behavior

Required `master` CI must use promoted exact pins. It must not depend on the
latest channel state at job start.

The existing `Supported platforms` aggregate remains the branch-protection
check. Documentation-only path filtering remains allowed. Any target or
dependency migration change must force all applicable native and sync lanes,
regardless of path filters.

Changes to any of these must classify as full code and sync impact:

- `tools/development-targets.json`;
- `build.zig`;
- `build.zig.zon`;
- `src/version.zig`;
- `src/build_options.zig`;
- `include/`;
- symbol manifests;
- upstream update tools; and
- workflow version settings.

CI evidence must print:

- turso.zig commit;
- exact Zig version;
- exact Rust and Cargo versions;
- Turso declared version and commit;
- header hashes;
- linkage and native library identity; and
- the target triple actually executed.

## 12. Candidate detection and promotion automation

### 12.1 Resolver

`tools/resolve-development-targets.sh` must:

- run read-only by default;
- query the official Zig JSON index;
- resolve Turso `refs/heads/main`;
- validate required fields and formats;
- verify candidate asset/archive checksums;
- read the Turso workspace version and Rust toolchain;
- hash both headers;
- compare candidates with the promoted manifest; and
- emit stable, machine-readable JSON.

It must not edit the repository unless explicitly invoked in a dedicated
automation branch with a `--write` option.

### 12.2 Cadence

- A cheap resolver runs daily at a non-zero minute.
- It exits successfully and silently when no input changed.
- Zig and Turso candidate tests run as independent jobs.
- The expensive full matrix runs only for a changed candidate or manual
  dispatch.
- A weekly job still exercises the currently promoted pins even when no
  candidate changed.

### 12.3 Classification

Every candidate produces one of:

| Classification | Meaning | Action |
| --- | --- | --- |
| `no-change` | Candidate equals promoted pin | No issue or PR |
| `routine` | Provenance-only change, allowlisted diff, all gates green | Draft PR; auto-merge eligible |
| `maintenance-required` | Source, ABI, behavior, toolchain, or test work needed | Issue plus evidence; no merge |
| `release-event` | New stable Zig or Turso release detected | Planning issue only |
| `infrastructure-failure` | Network, runner, rate-limit, or service failure | Retry, then infrastructure issue |

Stable-release detection is an independent notification lane. A release event
must not replace or suppress classification of a simultaneous development
candidate; both actions run when both conditions are present.

### 12.4 Routine-update boundary

A candidate is routine only if:

- the repository diff is limited to the target manifest and exact
  version/provenance copies;
- formatter output is unchanged;
- no wrapper or test source needs modification;
- C declarations, symbols, layouts, constants, and signatures are unchanged;
- ownership and behavior audits report no relevant upstream change;
- native dependencies and feature tokens are unchanged;
- the full required matrix passes; and
- no release or license metadata changed.

A comment-only header diff may be routine after explicit classification,
updated hash/provenance, and green gates.

Any uncertainty is `maintenance-required`.

### 12.5 Maintenance triggers

The following always require maintenance:

- a Zig formatter or compiler source diff;
- a Zig build API or standard-library failure;
- a Zig development version-family transition;
- a missing supported-host Zig asset;
- a Turso C declaration, symbol, layout, constant, or signature change;
- a Turso runtime version-family transition;
- an ownership, destructor, callback, or error-lifetime change;
- a feature token or native-link dependency change;
- a relevant license or notice change;
- any supported-platform failure;
- any required source modification; or
- a test result that cannot be classified as infrastructure.

### 12.6 Pull requests and issues

Automation branches use:

- `automation/zig-development-target`; and
- `automation/turso-development-target`.

Only one open automation pull request per upstream is allowed. New routine
candidates update the existing pull request rather than creating noise.

Maintenance issues use labels:

- `upstream-maintenance`;
- `zig` or `turso`;
- `breaking-change` when applicable; and
- `release-candidate` for stable upstream releases.

The issue body must include old and new revisions, classification reasons,
failing commands, links to logs/artifacts, relevant upstream commits, and a
copy-paste local reproduction command. Issues are deduplicated by upstream and
candidate revision.

## 13. Codex-assisted maintenance

Deterministic scripts and CI decide whether a candidate is green. Codex may
assist only after evidence exists.

For `maintenance-required`, Codex may:

- summarize relevant upstream commits;
- group failures by likely root cause;
- compare changed APIs and ownership contracts;
- propose the smallest migration patch;
- run the required checks in an isolated worktree; and
- open or update a draft pull request.

Codex-generated changes must remain draft and require human review when they
touch source, declarations, symbols, layouts, ownership, behavior, security,
or platform claims.

A future root `AGENTS.md` should encode:

- never update Zig and Turso in one pull request;
- never modify stable branches during nightly maintenance;
- exact verification commands;
- hard human-review boundaries;
- supported-platform claims; and
- the requirement to stop and report uncertain ABI or ownership semantics.

Initially, a maintenance email leads to an explicit voice-driven Codex task.
Unattended Codex diagnosis may be added later in a dedicated worktree after the
first three maintenance events demonstrate that the evidence and prompts are
reliable.

## 14. Notifications

The notification mechanism is:

1. scheduled GitHub Actions detects and classifies a candidate;
2. routine green updates create or update a pull request without email noise;
3. maintenance creates or updates an assigned GitHub issue;
4. the responsible workflow ends with a clear failing/attention-required
   summary; and
5. GitHub sends the maintainer's configured notification email to Fastmail.

The maintainer should enable GitHub Actions email notifications for failed
workflows and issue assignment/mention notifications.

The automation must suppress duplicate messages for the same candidate. An
infrastructure failure is retried before notification. A resolved maintenance
issue is reopened only when the same unresolved candidate becomes relevant
again.

## 15. Release separation

Development inputs are allowed on `master` but forbidden for stable
publication.

Release tooling must reject:

- a Zig version containing `-dev`;
- a Turso version containing `-pre`;
- missing Turso tag provenance;
- a Turso tag that does not peel to the recorded commit;
- a dirty tree;
- mismatched target-manifest copies; and
- a release attempt from an unprotected development branch.

When stable Zig and Turso versions are selected later, release preparation is a
separate migration. It replaces development provenance with real stable tag
provenance, runs the full release matrix, and makes a deliberate package
version decision.

## 16. Security requirements

- Use full commit IDs, never abbreviated IDs, in machine-readable provenance.
- Verify downloaded archives against official SHA-256 values.
- Keep the Turso dependency lazy for native-independent builds.
- Do not run candidate repository code in a job that holds write credentials.
- Candidate test jobs receive `contents: read`.
- A separate job with narrowly scoped `contents`, `pull-requests`, or `issues`
  write permission performs GitHub mutations.
- Do not expose API keys or mailbox credentials to upstream builds or tests.
- Pin third-party GitHub Actions to reviewed commit IDs.
- Preserve deterministic path remapping and source epochs.
- Retain candidate evidence for at least seven days.
- Never weaken runtime-version rejection to make a candidate pass.

## 17. Delivery sequence

### Phase 0: specification

- Merge this specification only.
- Make no dependency or source changes.

### Phase 1: target tooling

- Add the machine-readable target manifest with current stable pins.
- Add resolver and consistency-check scripts.
- Make drift tooling consume explicit candidate/provenance inputs.
- Keep required CI on Zig `0.16.0` and Turso `v0.7.1`.

### Phase 2: Zig development target

- Resolve and freeze one Zig candidate.
- Implement only the Zig migration.
- Run required and extended gates against Turso `v0.7.1`.
- Merge after supported-platform CI is green.

### Phase 3: Turso development target

- Resolve and freeze one Turso candidate.
- Complete ABI, ownership, behavior, documentation, and provenance review.
- Run required and extended gates using the promoted Zig development compiler.
- Merge after all supported-platform and sync evidence is green.

### Phase 4: promotion automation

- Add candidate classification, automation branches, draft PRs, issues, and
  deduplication.
- Run in shadow mode for three candidate cycles.
- During shadow mode, automation proposes but never auto-merges.
- Enable routine auto-merge only after the three classifications are manually
  confirmed.

### Phase 5: optional Codex automation

- Add repository guidance and a reusable maintenance prompt or skill.
- Test it on historical failure artifacts.
- Keep generated fixes draft-only.
- Enable unattended worktree diagnosis only after explicit review.

## 18. Rollback

Each upstream migration must be revertible as one focused pull request.

If a promoted Zig build regresses:

1. revert the Zig migration commit;
2. restore the previous exact compiler pin and checksums;
3. open a maintenance issue for the rejected candidate; and
4. keep discovery active for the next Zig revision.

If a promoted Turso commit regresses:

1. revert the complete Turso migration, including headers and provenance;
2. restore the previous commit-addressed archive and runtime version;
3. attach the regression evidence to a maintenance issue; and
4. test the next Turso candidate independently.

Do not rewrite `master` or move stable refs during rollback.

## 19. Final acceptance criteria

The migration is complete when:

- `master` still declares turso.zig `0.1.1`;
- `v0.1.1-stable` remains unchanged;
- `master` records an exact Zig development version and Turso development
  commit;
- no required build uses a floating channel reference;
- every provenance copy passes the consistency checker;
- the supported-platform aggregate passes;
- the extended dynamic, system, sync, fault, Valgrind, and soak gates pass;
- source packages are reproducible and clean consumers build;
- runtime-version mismatch remains rejected;
- scheduled detection reports no unpromoted candidate at the time of final
  verification;
- routine and maintenance classifications have fixture-backed tests;
- notification deduplication is tested;
- stable publication rejects development inputs; and
- README, contributing, updating, release, API, ABI, test, and platform
  documentation agree with the implemented channel policy.
