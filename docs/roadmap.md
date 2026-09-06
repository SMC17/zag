# Roadmap

zag has a tested substrate, not a finished workbench. This roadmap separates
what the repository demonstrates today from work that still needs design,
implementation and evaluation.

This file decides the order the work happens in. `docs/competitive-position.md`
says where zag stands against other terminals and what it cannot do yet; it
points here rather than keeping an order of its own, so that two documents
cannot give two answers.

## Completed foundation

The current code provides typed events, a verified hash chain, immutable
content-addressed command output, block and workspace projections, a Linux
pseudoterminal, shell boundaries, structured history, typed capability policy,
standards profiles, generated interchange files and automated conformance
checks.

The persistence path classifies incomplete and malformed records separately,
refuses to extend either one, checks the exact on-disk prefix under a lock and
appends only new records. Command deadlines use a monotonic clock, terminate a
process group and record a timeout.

`zag term` runs a person's own shell on that pseudoterminal and records the
session. Command boundaries carry a per-session secret, so output printed by a
program cannot forge one. `zig build bench` measures the paths that sit in a hot
loop, best of several runs, and prints the build mode and the spread with each
number.

`zag objects` now performs the non-destructive whole-store audit needed before
garbage collection: missing, changed, size-mismatched, unreferenced and
unexpected entries are reported. `zag recover` now separates a read-only plan
from an explicitly approved truncation, preserves the exact original bytes
under their digest, rechecks the locked source and verifies the recovered
prefix. Normal workspace open never invokes that path. Final event-log, object
and recovery-evidence entries reject symbolic links. A flush is rejected before
it would make an active log exceed 64 MiB.

These statements are covered by automated tests. They do not establish
power-loss survival on every filesystem, hostile tamper resistance, a safe
garbage collector, a complete terminal, a graphical product or organisational
certification.

## Priority 0: protect the record

- Build a safe garbage collector on the read-only object audit. Collection must
  require separate approval, recheck the log under a lock and preserve a
  manifest of every object it removes.
- Publish signed external checkpoints for event-log heads. A local hash chain
  alone cannot detect replacement of the whole chain by the same attacker.
- Expand the truncation property tests and add fuzz targets for JSON Lines
  recovery, canonical event encoding, shell boundary capture and the terminal
  parser.
- Define crash tests for failure before object sync, during event append and
  after event sync. Include directory-entry durability and a real recovery
  exercise after each injected failure.

## Priority 1: enforce the security model where it executes

- Open files relative to a workspace directory handle with symlink-safe,
  beneath-only resolution. Rejecting a symbolic link in a record's final path
  component and checking lexical policy are useful, but neither is a complete
  filesystem sandbox.
- Implement concrete typed tool executors. Each executor must consume the
  policy decision it was given and must not reinterpret a command string.
- Enforce network host allowlists at the connection boundary, including name
  resolution, redirects and address changes. A request type alone is not an
  enforcement control.
- Review `docs/threat-model.md` with local users, malicious repositories,
  compromised child processes, model providers and remote clients in scope.
- Add secret detection and redaction policy for terminal output, model context,
  diagnostic bundles and security reports.

## Priority 2: make the terminal one a person can live in

Everything here is small, and each item ends in something a person can use.
`zag term` records a session today, but nothing about it can be changed without
editing Zig.

- Read a settings file for the shell, the scrollback size, the colours and the
  key bindings. Report an unreadable setting by name and carry on with the
  default rather than refusing to start.
- Show the state of the session while it runs: the working directory, the
  branch, and whether the shell is marking its boundaries.
- Hold more than one shell in one recorded session, with each block naming the
  pane it came from.
- Index the blocks, so a query does not walk them. State the size the index is
  built for and measure a query at that size.

## Priority 3: finish the large surfaces

- Build the graphical renderer against the existing semantic accessibility
  tree, then evaluate complete tasks with keyboard and screen-reader users.
- Build the editor surface and a language-server client over the existing
  document and diagnostic models.
- Implement the daemon interface described by the generated OpenAPI document,
  with authentication, authorisation, version negotiation and backpressure.
- Add model-provider adapters behind the policy and transparency boundary. They
  depend on the typed executors in Priority 1: a provider with nothing to
  execute under a decision proves nothing about the boundary.
- Add macOS pseudoterminal and Windows ConPTY implementations, and the terminal
  settings each one needs, with the same behavioural test suite used on Linux.
- Define remote replay, reconnect and conflict semantics before allowing more
  than one machine to append to a workspace.

## Priority 4: release and interoperability

- Turn the compile-only entries in `docs/platform-support.md` into supported
  targets with native test evidence. Add performance budgets and repeatable
  terminal-latency and large-log benchmarks.
- Produce checksummed, signed release artifacts and a software bill of
  materials. Document the build provenance and rollback procedure.
- Exercise OpenAPI, JSON Schema, JSON-LD, SKOS and llms.txt with independent
  consumers. Add DITA, DocBook, S1000D or iiRDS output only where a named
  exchange profile requires it.
- Run the required human evaluations for plain language, easy-to-read content,
  accessibility, risk treatments and challenge routes. Record the scope, date,
  participants and unresolved findings.
- Establish versioning, migration and retention rules before declaring the
  event format stable.

## Evidence required to call a milestone complete

| Milestone | Required evidence |
| --- | --- |
| Durable record | Fault-injection tests, object audit, recovery exercise and signed checkpoint verification |
| Configurable terminal | A settings file read at start, a named report for each unreadable setting, and tests for the defaults |
| Many shells in one session | Two shells recorded in one log, each block naming its pane, and the log verifying afterwards |
| Fast recall | A stated index size, a measured query at that size, and the measurement repeated by the benchmark harness |
| Enforced agent boundary | Executor integration tests, path and network escape tests, and an independent security review |
| Accessible desktop | Automated checks plus task completion with keyboard and screen-reader users |
| Remote workspace | Authentication review, reconnect tests, conflict tests and load results with declared units |
| Stable release | Platform matrix, migration test, signed artifacts, provenance, release notes and rollback exercise |
| Standards claim | Named profile and edition, requirement-level evidence, human findings and explicit exclusions |

`zag doctor` remains the short statement of shipped capability.
`docs/standards-conformance.md` remains the boundary on standards claims.
