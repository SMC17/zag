+++
title = "Release check"
summary = "The steps this repository runs before a change is proposed."
owner = "workbench maintainers"
state = "approved"
review_due = "2027-03-04T00:00:00Z"
concepts = ["workflow", "execution-graph", "conformance-profile"]
tags = ["build"]
+++

Run `zag workflow` to see this graph with its stages and its capabilities.

1. `zig build test` runs the library, the tool and the daemon tests.
2. `zig build` builds `zag` and `zagd`.
3. `zag check` audits the repository against its standards profile.
4. `zag emit` regenerates the schemas, the vocabulary and the generated docs.
5. `git diff --exit-code` fails when a generated file has fallen behind the code.
6. `zag lint` checks the product's own text against the plain-language rules.
7. `zagd verify` checks the event log and the command-output store.
8. `zig build bench -Doptimize=ReleaseFast` measures the paths in a hot loop.
9. `zig build -Dtarget=<target>` compiles for macOS and for Windows. A compile
   is not a support claim: see `docs/platform-support.md`.

Continuous integration runs all of these. Compare a benchmark number only with
another number from the same machine.

A step that needs a person, such as publishing, waits for a person. The daemon
reports it and stops.
