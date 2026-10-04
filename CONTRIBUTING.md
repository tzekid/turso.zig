# Contributing

`master` pins exact inputs: the Zig release in `.zigversion` and the Turso
commit recorded in `src/version.zig` and `build.zig.zon`. Updating either is a
deliberate change; see [Updating Turso](docs/UPDATING_TURSO.md) for the ABI and
ownership audit.

Before submitting a change, use the exact compiler in `.zigversion`, format the
Zig sources, and run the smallest relevant gates from
[the test matrix](docs/TEST_MATRIX.md). Native-boundary changes require the
base and sync ABI checks as well as target-native CI.

A change involving compiler adaptation, public declarations, symbols, layouts,
ownership, behavior, licenses, or platform claims requires human review.
