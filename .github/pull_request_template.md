## Why

Describe the user problem or failure this change addresses.

## What changed

Describe the smallest important changes and any interface or data migration.

## Evidence

- [ ] I added or updated a test that fails without this change.
- [ ] `zig build test --summary all` passes.
- [ ] `zig build check --summary all` passes.
- [ ] `zig build emit` leaves no uncommitted generated change.
- [ ] I tested the affected user path by hand, or explained why that does not apply.

## Boundaries and risk

- Security, privacy or accessibility impact:
- Compatibility or migration impact:
- Work deliberately left out:
