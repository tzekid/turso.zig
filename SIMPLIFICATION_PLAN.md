# turso.zig simplification plan

Planning snapshot: 2026-09-04. Implemented and reviewed on 2026-09-05.

## Current state and evidence

- Local `ecosystem` is `40e7760`; recorded `origin/master` is `797b11b`, with two local and three default unique commits. Default has newer upstream-maintenance controls missing from the local branch.
- The local experiment adds a roughly 1,700-line pool, about 850 lines of pool tests, and an example. Sparkdate still owns its application pool; Nutritio uses the basic database API. The inspected application imports do not establish a current consumer for the new exported pool.
- Default CI already selects affected code/sync groups and supports Linux x64/ARM, macOS ARM, and Windows x64. Extended soak/fault/platform coverage is already scheduled or manually dispatched. Moving it off every PR is not an outstanding optimization.
- `build.zig` repeats ordinary example construction, but some examples intentionally only compile: encryption must not expose a key through build arguments, and sync is opt-in. ABI, ownership, allocation, partial-write, and sync-lifetime tests protect a native C boundary and are not disposable boilerplate.
- The README links a missing `SECURITY.md`. Remote-ref verification finds hosted `v0.1.0` and the `v0.1.1-stable` branch, but no hosted `v0.1.1` tag despite a local tag of that name. Default's tagged-install recommendation is therefore not disproved by the local tag. This needs precise channel documentation, not automatic version promotion.

## Intended result

Keep the thin native binding, reproducible inputs, supported platforms, and behavioral guarantees. Simplify repetitive build wiring and inaccurate documentation without promoting an unneeded pool, weakening native-boundary tests, or undoing upstream maintenance controls.

## Implementation sequence

1. Refresh remote refs and use an isolated current-default checkout. Preserve the local pool work in a recoverable ref; do not merge the ecosystem branch wholesale. Check current application dependency pins/imports before treating any exported API as removable. Leave the unused-by-inspected-consumers pool experiment unpromoted in this scope; do not rewrite application pools to justify it.
2. Keep `tools/development-targets.json` as the existing promoted-input authority and preserve export/check tooling. Do not add parallel pin files or change Zig, Rust, Turso revisions, public ABI, or release channel as part of cleanup.
3. Replace the repetitive ordinary-example declarations with one small explicit list/helper only where target, imports, and run behavior match. Keep encryption compile-only and opt-in sync paths explicit. Preserve public step names and installation behavior; do not generate a build DSL or merge examples with different contracts.
4. Map executed test roots to failure coverage and measure the affected existing lanes before deleting duplicates. Retain cross-platform tests, native fixtures, ReleaseFast ownership invariant enforcement, allocator cleanup, transaction/durability, short-write/ENOSPC, and sync cancellation/lifetime checks. A test with smoke in its name may contain real ABI/lifecycle evidence; inspect its assertions rather than deleting by label.
5. Fix broken documentation links and reconcile install guidance with verified hosted tags/releases and their exact compiler/upstream provenance. Do not label a development-upstream tag stable merely because its version looks newer. Remove the nonexistent security-policy link rather than inventing an unapproved support policy.
6. Preserve the existing maintenance episode lifecycle, frozen candidates, draft PR behavior, and stable-channel boundaries. This user-directed cleanup is distinct from an automated upstream update; do not modify or merge outstanding maintenance candidates while carrying it out.

## Verification and delivery

- Run formatting, shell validation if changed, native-independent tests, default real database tests/examples, README example compilation, and the packaged consumer against the unchanged promoted inputs. Record the actual step list and affected lane timings; do not claim a speedup from code-line counts.
- A build-graph change must preserve ordinary example execution and the encryption/sync compile-only or opt-in behavior. Run the relevant supported-platform hosted checks and sync feature configuration where the changed helper affects them. Do not require every long soak to rerun for a documentation-only change; do not waive an applicable required gate for a build change.
- Preserve symbol/layout/ownership contracts and installed module paths. Exercise consumers in disposable checkouts without updating Sparkdate, Nutritio, or any other real sibling pin. No application database or service needs to be touched.
- Review API/package compatibility, feature selection, test ownership, and automation behavior adversarially; repair findings and repeat until a complete pass has no new or unresolved blockers. For this explicitly user-directed cleanup, push only reviewed task commits to the agreed default branch and verify the remote revision and applicable checks.
- No service deployment, stable-branch edits, tag movement, or release publication. Keep the automated upstream maintenance policy in `.github/automation/upstream-maintenance.md` intact; its draft-only/human-review rules continue to govern those separate maintenance episodes.

## Planning review

- Pass 1 found that extended coverage is already outside ordinary PR runs, that a generic example loop could accidentally execute encryption/sync examples, and that a local `v0.1.1` tag is not present on the remote. The plan preserves feature-specific example behavior and distinguishes hosted releases, the stable maintenance branch, and local refs. Debug and ReleaseFast ownership checks are distinct guarantees, not duplicate tests to remove.
- Pass 2 inspected ordinary/special example wiring, the input manifest/checker, remote release refs, application imports, and the default maintenance contract. No unresolved or new planning blockers were found. No public pool adoption, stable release, or automatic maintenance merge is implied by this cleanup.

## Implementation and review result

- Replaced nine identical ordinary-example declarations with one explicit list.
  All existing executable names, descriptions, target/options/imports, run steps,
  and six Valgrind installation selections remain. Encryption and opt-in sync
  compilation stay separate; the aggregate description now says what runs and
  what only compiles. All 33 prior explicit public step names remain available.
- Kept the complete test, benchmark, ABI, native configuration, and ownership
  build wiring unchanged. No library source, header, native fixture, input pin,
  maintenance episode rule, stable branch, or tag was changed. The original
  `ecosystem` checkout and its unneeded-by-current-consumers pool remain intact.
- README pairs the verified hosted `v0.1.0` tag with Zig 0.16.0/Turso 0.7.0,
  the `v0.1.1-stable` branch with Zig 0.16.0/Turso 0.7.1, and development master
  with the exact promoted inputs. GitHub lists only v0.1.0 as a published release;
  no v0.1.1 tag was published by this work.
- Removed the nonexistent security-policy references from README and the bug
  template, plus absent AGENTS/code-of-conduct/security files from source export
  paths. No replacement policy was invented. All 28 local README links resolve.

Review pass 1 confirmed ordinary versus compile-only example ownership, exact
memcheck installation selection, and unchanged test/native wiring. Pass 2 found
an existing sync-example compile failure on the promoted Zig: `Uri.getHost` was
removed. The example now uses `HostName.fromUri`; the unreachable IPv6-literal
comparison was removed because that hostname API rejects such literals. A
focused disposable check confirmed HTTP allowance only for explicit 127.0.0.1
and localhost, rejecting remote hosts, lookalikes, userinfo lookalikes, malformed
URLs, HTTPS (which needs no HTTP exception), and IPv6 literals. The existing sync
CI lane now compiles this example so the compatibility gap cannot stay hidden.

## Verification and delivery

- Baseline `test examples -Doptimize=Debug`: 92/92 steps, 115/115 tests.
- Candidate `test examples build-memcheck-smokes -Doptimize=Debug`: 99/99 steps,
  including the seven additional install/aggregate steps. Its 21 newly executed
  tests passed and the remaining test steps reused successful cache results.
  No test reduction or speedup is claimed. Ordinary example execution in this
  run ranged from 22 to 411 ms; the native cold Debug build took 1m46s.
- Native-independent Debug target: 25/25 steps. ReleaseFast ownership invariant
  target: 7/7 steps. ABI symbols, README example compilation, shell syntax and
  ShellCheck, promoted-input consistency, formatting, YAML, and diff checks passed.
- Exported source consumer in system mode: 5/5 steps using the unchanged pinned
  native artifact. Sync-enabled ReleaseSafe `examples`: 31/31 steps after the
  API correction; ordinary bodies ran in 4–10 ms, encryption and sync installed
  without execution. Sync's cold native build took 3m30s. The disabled-sync target
  still refuses invocation without `-Dsync=true`.
- Final exported sync example compiled successfully in ReleaseSafe system mode
  (6/6 steps), with all changed package inputs matching the reviewed source.
  Final review confirmed the narrow API change, unchanged consumer pins, source
  export contents, and public steps; no new or unresolved local blockers remain.
  Hosted supported-platform and sync checks must pass for the pushed commit.

Push only this reviewed default-branch change. No service deployment, consumer
pin update, stable-channel change, or release publication is appropriate for
this library/build/example/documentation cleanup.

## Follow-up: 2026-09-20

### Current scope and acceptance

Default is `a5250717a895ee15da64f1d5eb0c608b306c6438`, Zig2085 from the
existing promoted-input manifest, unchanged Turso `6e527a7` and Rust1.88.
The original `ecosystem` checkout at40e7760, local pool experiment, historical
plan, local tags, stable branch and application dependency pins are preserved.
The clean follow-up checkout uses current master. No AGENTS file is tracked.
The separate automated maintenance episode policy does not govern this explicit
owner-authorized audit; its frozen candidates and branches remain untouched.

Current exact-source CI34396261392 passed all supported native platform, sync
and aggregate jobs. Extended35499979973 passed native dynamic/system linkage,
Linux faults, real local-server sync and lifecycle soak. Source export has135
files,229231compressed bytes and no generated cache entries. No remaining
runtime/build/example defect is established by inspection; do not manufacture
a rewrite or promote the unused pool to produce a change.

1. Recheck default native database/ownership/ABI/durability and ordinary examples
   with the promoted compiler. Keep encryption compile-only and sync opt-in.
2. Recheck ReleaseFast ownership invariants, sync workflows/ABI and enabled
   example compilation. Preserve local-only credential-free tests and explicit
   loopback HTTP policy. Do not send remote credentials or publish diagnostic
   response bodies.
3. Build/run the exported source consumer and compile its sync example against
   the exact existing native artifacts; inspect exported inputs and README
   compilation. Keep all application pins unchanged. If a concrete finding
   appears, make the narrow repair and reset the implementation review count.
4. Require two complete clean implementation reviews. Commit only this audit
   record if behavior/package remain correct. Push default and verify its exact
   configured CI, including intentional path-filtered skips. No service exists
   to deploy; SDK publication does not imply consumer adoption, new tags,
   stable-channel edits, prebuilt artifacts or release publication.

### Follow-up plan reviews

- Pass1, complete API/behavior/security/ownership perspective: traced ordinary
  versus encryption/sync build branches, current sync URI handling, retained
  native and ownership tests, consumer modules and platform boundaries. The
  acceptance exercises real database and exported use without weakening the
  FFI or inventing another test matrix. Zero findings; clean1.
- Pass2, complete delivery/preservation perspective: verified remote default,
  all worktrees, experimental refs, hosted tag/stable identities, current exact
  CI/extended runs, promoted input authority and clean package contents. The
  plan preserves automated candidates and each sibling pin and correctly
  distinguishes source publication from adoption. Zero findings; clean2.

### Follow-up implementation reviews and delivery

- Pass1, complete functional/security/lifetime review: current default passes
  `test examples` Debug (92/92steps,136/136tests), ReleaseFast ownership probes
  (7/7steps), and ReleaseSafe sync workflows/ABI plus example compilation.
  Rechecked explicit example registration, compile-only encryption, opt-in sync
  refusal, HostName URI handling, fixed transport error categories, native
  ownership and failure cleanup. Existing tests retain real database durability
  and negative native-boundary assertions. No code repair is warranted. Zero
  findings; clean1.
- Pass2, complete package/operations/preservation review: base exported consumer
  executes5/5steps, sync consumer6/6, exported sync example6/6. All48base ABI
  symbols match; promoted inputs are internally consistent; README compiles;
  archive135files has no generated caches. Exact existing platform and extended
  CI cover unchanged runtime/package code, including real local sync and native
  non-Linux linkage. Original pool checkout/plan, all tags and stable ref match
  their saved identities. Only this audit record changed; no application pin,
  runtime service or maintenance candidate was modified. Zero findings; clean2.

Publish the audit record to default and check its exact CI. Documentation path
filtering may intentionally skip unchanged native jobs; their current-source
success above is recorded separately. The exported SDK contents remain unchanged.
