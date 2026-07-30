# Contributing

Development on `master` follows exact, reproducible snapshots of Zig `master`
and Turso `main`. See
[Development channels](docs/DEVELOPMENT_CHANNELS.md) for the policy and
[Updating Turso](docs/UPDATING_TURSO.md) for the ABI and ownership audit.

Before submitting a change, use the exact compiler recorded in
`tools/development-targets.json`, run `tools/check-development-targets.sh`,
format the Zig sources, and run the smallest relevant gates from
[the test matrix](docs/TEST_MATRIX.md). Native-boundary changes require the
base and sync ABI checks as well as target-native CI.

Automated candidate pull requests are drafts. A change involving compiler
adaptation, public declarations, symbols, layouts, ownership, behavior,
licenses, or platform claims requires human review. Stable branches and
release tags are outside nightly automation.
