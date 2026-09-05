# Workflows

`ci.yml` is the whole gate. It installs Zig, runs `zig build check`, then makes
sure the generated files in `schemas/`, `vocab/` and `docs/` still match the
code that produces them.

Zig comes from the `ziglang` package on the Python package index, which ships
the official toolchain. That keeps the workflow to one install step, and keeps
it working when a runner image changes.
