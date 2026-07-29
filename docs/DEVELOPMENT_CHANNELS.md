# Development and release channels

This document records the branch policy and the implementation plan for moving
`master` to upstream development channels. It does not claim that the migration
has already happened.

## Locked checkpoint

`v0.1.1-stable` was created from the exact local `master` state captured before
this plan was added, then corrected at commit
`ad1f1c0141407789db320bd6a9c9b68832d788f5` to declare version `0.1.1`. The
branch is a maintenance checkpoint. It does not
move or replace the existing `v0.1.0` release tag, which points to commit
`43d0b9d48eaf873453ee6882b301c2421850ade3`.

The checkpoint uses stable Zig `0.16.0` and stable Turso `v0.7.1`. Its package
metadata says `0.1.1`. Never reuse or move the existing `v0.1.0` tag.

## Branch contract

- `master` is the rolling integration branch. It targets the latest Zig
  `master` build and Turso `main` revision that pass this repository's required
  checks.
- `v0.1.1-stable` preserves the current stable-input line. Only focused
  compatibility, security, documentation, and bug fixes belong there.
- `vX.Y.Z` tags are immutable releases. A release tag may use only stable Zig
  and stable Turso inputs.
- A new stable branch is cut when a new stable turso.zig line is released, using
  the established `vX.Y.Z-stable` naming convention.
- Consumers of `master` should record the resolved turso.zig commit. A moving
  branch name is a discovery channel, not reproducible dependency provenance.

## Floating channels, immutable revisions

Following nightly channels must not make an individual turso.zig commit change
underneath its users.

For Zig, `master` discovers the newest build from the official download index,
then records the exact development version used by required CI. The version
must agree across `build.zig.zon`, `src/version.zig`, workflows, packaging
checks, consumer fixtures, and documentation. A scheduled candidate job may use
the literal `master` channel, but required tests use the exact promoted build.

For Turso, `main` discovers the candidate revision, then turso.zig pins its full
commit ID, commit archive URL, Zig package hash, source timestamp, runtime
version, vendored headers, and header hashes. The dependency URL must not point
at a moving `main` archive. A commit is promoted only after the C ABI and safe
wrapper have been reviewed together.

This gives `master` the latest *passing* development pair while retaining
reproducible builds and auditable native provenance.

## Version policy

The current development and stable-maintenance line is `0.1.1`. Nightly
dependency refreshes do not cause releases by themselves.

The next minor version is reserved for a future deliberate release decision,
such as adopting a new stable Zig minor baseline, a new stable Turso minor/ABI
baseline, or making a breaking turso.zig API change. It is not a fallback
version for development work.

A stable release is eligible only when:

1. both the selected Zig and Turso versions are stable releases;
2. all release inputs are immutable and their provenance is recorded;
3. the complete required platform, ABI, ownership, sync, packaging, and
   downstream-consumer matrix passes; and
4. the release is useful enough to justify maintaining another stable line.

There is no requirement to release for every upstream patch or prerelease.

## Current development candidates

As observed on 2026-07-29:

| Input | Candidate |
| --- | --- |
| Zig development channel | `0.17.0-dev.1503+1f1bee62e` |
| Turso development channel | `main` at `5346dfe48894c1c81d03a35d01a8c91baf737278` |
| Version declared by Turso `main` | `0.8.0-pre.2` |
| Latest stable Turso release | `v0.7.1` |
| Latest `0.7.x` prerelease tag | `v0.7.2-pre.2` |

These values are evidence for the first migration, not permanent policy
constants. Because the goal is to follow Turso development, its `main` revision
takes precedence over the older `0.7.2-pre.2` tag.

## Implementation plan

### 1. Reconcile and protect the branches

Bring local `master` up to date with `origin/master` before starting migration
commits. Protect stable branches from force pushes and require their own CI on
push. Keep Zig `0.16.0` and Turso `v0.7.1` unchanged on
`v0.1.1-stable`.

### 2. Migrate Zig independently

Make the Zig migration one reviewable commit before changing Turso:

1. promote the newest Zig `master` build to an exact recorded version;
2. update build APIs and source syntax for that compiler;
3. update all workflow installers, including direct Windows and musl download
   paths that currently assume a stable release URL;
4. update package, consumer, formatting, documentation, and release-tool
   version assertions; and
5. require pure tests, native tests, examples, docs, and clean-consumer tests to
   pass before starting the Turso migration.

### 3. Migrate Turso as an ABI change

Follow [UPDATING_TURSO.md](UPDATING_TURSO.md), with `main` as the discovery
source and its promoted commit as immutable provenance:

1. pin the selected Turso `main` commit archive and package hash;
2. record the commit timestamp and declared prerelease version, without
   inventing a release tag or tag object;
3. vendor and hash both SDK Kit headers;
4. review raw declarations, exported symbols, layouts, ownership, runtime
   version checks, crate features, native dependencies, and notices;
5. adapt the safe and sync layers for every reviewed ABI or behavior change;
   and
6. pass the complete source/system, static/dynamic, base/sync, platform, soak,
   fault, package, and local-server sync matrix.

The Zig and Turso migrations stay separate so failures can be attributed to one
moving upstream at a time.

### 4. Turn drift checks into promotion checks

Keep required `master` CI reproducible with exact pins. Extend the scheduled
drift workflow to:

- resolve the latest Zig `master` build and Turso `main` commit;
- do nothing when both already match the promoted pins;
- test new candidates without changing release provenance;
- prepare a small update pull request when candidates pass; and
- retain logs and open or update a tracking issue when a candidate needs code
  migration.

Do not push untested dependency updates directly to `master`. Remove the
advisory `continue-on-error` behavior once the initial Zig migration is green,
so drift failures become visible maintenance work.

### 5. Separate development and release gates

Required development CI accepts exact `-dev` and `-pre` inputs. Release
packaging must reject them and require stable Zig version syntax, an annotated
stable Turso tag, its peeled commit, and a clean stable-branch provenance table.

Add stable branches to workflow branch filters. A stable branch continues to
use the toolchain and Turso release recorded on that branch; it must not inherit
nightly pins from `master`.

### 6. Update the public contract

When the migration lands:

- describe `master` as the latest-passing nightly channel in `README.md`;
- keep install examples commit-pinned and continue recommending tags for
  stable users;
- update `CONTRIBUTING.md`, `CHANGELOG.md`, `RELEASING.md`,
  `UPDATING_TURSO.md`, platform claims, and API coverage;
- distinguish development-commit provenance from release-tag provenance in
  `src/version.zig`; and
- label unsupported or temporarily broken nightly platforms honestly rather
  than carrying forward stable claims without evidence.

## Completion criteria

The transition is complete when:

- `v0.1.1-stable` still resolves to its locked checkpoint unless an intentional
  maintenance commit is added;
- `master` records and passes the latest promoted Zig and Turso development
  revisions;
- scheduled checks detect newer upstream revisions and provide an actionable
  promotion path;
- fresh consumers can build from the recorded `master` commit;
- nightly provenance is reproducible; and
- release tooling cannot publish a stable turso.zig tag from prerelease inputs.
