## Summary

<!-- What changes for users? -->

## Motivation

<!-- Why is this needed? Link the issue or upstream ABI evidence. -->

## Validation

<!-- List the exact commands and relevant target-native CI lanes. -->

- [ ] `zig fmt --check .`
- [ ] `zig build test`
- [ ] `zig build examples`
- [ ] `zig build docs`
- [ ] Sync checks run or not applicable

## Compatibility and ownership

- [ ] Public API and migration impact is documented
- [ ] Native ownership and borrowed lifetimes are unchanged or explained
- [ ] Header, symbol, and runtime-version checks are updated when the ABI changes
- [ ] No secret, credential, or encryption key can enter diagnostics

## Automated or AI assistance

<!-- State whether assistance was used, what it produced, and how you reviewed it. -->
