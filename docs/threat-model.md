# Threat model

This document describes the security boundary implemented by the current zag
substrate. It is a design review aid, not a claim that the unfinished product
is secure. Review it whenever a new executor, provider, network listener or
credential path is added.

## Scope and assets

The current scope is one local workspace, its child processes and the files
under `.workspace/`. The graphical client, remote daemon interface, model
providers and concrete agent tool executors are not implemented and are not
inside the evaluated boundary.

Assets that need protection are:

- source files and uncommitted work;
- the event log and command-output objects;
- capability decisions and approval records;
- credentials and personal data visible to a command or model;
- the accuracy of command text, output, status, actor and provenance records.

## Trust boundaries

Treat repository text, child-process output, model output, tool arguments and
files read from disk as untrusted. A policy decision is trusted only for the
exact typed request and resource it records. The executor that consumes that
decision must still enforce it at the operating-system boundary.

The local operating system, Zig toolchain and person who controls the workspace
are trusted in the current design. A hostile local administrator can replace
the program, its memory and all local records; local hashing does not defend
against that actor.

## Threats and current controls

| ID | Threat | Current control | Residual work |
| --- | --- | --- | --- |
| T1 | Repository text tells an agent that it has more permission | Permissions come only from typed policy; instruction files that try to grant permission are reported | Test every concrete executor against the decision it receives |
| T2 | A path uses `..` or a symlink to escape the workspace | Policy rejects lexical traversal and mismatched path roots; final event-log, object and recovery-evidence entries reject symbolic links | Open every executor path through a workspace directory handle with beneath-only resolution; parent components are not yet a sandbox boundary |
| T3 | A command string gains unintended shell meaning | Agent tool requests carry argument vectors; the interactive `zag run` command is explicitly a person-requested shell command | Concrete executors must never rebuild an argument vector as a shell string |
| T4 | An event is edited, reordered or appended by a stale writer | Content and chain hashes, strict decoding, prefix fingerprint and an exclusive writer lock | Signed external heads are needed to detect whole-log replacement, truncation or a hostile non-cooperating writer |
| T5 | A crash commits partial state | Objects are immutable and synchronized before events; incomplete and malformed log tails seal the workspace; recovery requires an explicit flag and preserves the exact original log first | Add power-loss fault injection, directory-entry durability checks and recovery exercises on real filesystems |
| T6 | A child prints OSC 133 bytes to forge a command boundary or status | Service-owned command wrappers use a random marker token that is removed before the command starts; control marks and parser states are bounded | Extend authenticated markers to interactive shell hooks; an ordinary `boundaryFromShell` value alone is not proof of origin |
| T7 | A child floods output or never exits | Captured output is bounded; deadlines use monotonic time and terminate the process group, escalating to `KILL` | Add operating-system CPU, memory, process-count and disk quotas |
| T8 | Terminal output discloses a secret | New event and object files use owner-only permissions where POSIX permissions exist | Add detection and redaction before output enters model context or diagnostic bundles |
| T9 | A terminal sequence corrupts memory or parser state | Fixed parser bounds, UTF-8 replacement, screen bounds and regression tests | Add coverage-guided fuzzing and differential tests against a mature terminal parser |
| T10 | A build input is replaced upstream | No package dependencies; CI pins the checkout action and verifies the Zig archive digest | Add signed release provenance, artifact signing and an independently verified toolchain policy |
| T11 | A future remote client bypasses local policy | No network listener exists today | Define authentication, per-request authorisation, replay protection, rate limits and audit before listening on a socket |

## Security invariants

The following properties must remain release-gate tests:

- A torn line, malformed complete line or broken hash chain seals the log.
- A stale writer cannot replace records written after it opened.
- An event-log flush appends without changing the accepted byte prefix.
- Changed or missing content objects are reported as different failures.
- A whole-store audit reports missing, changed, size-mismatched, unreferenced
  and unexpected entries without changing any of them.
- Recovery plans change nothing; approved recovery preserves and verifies the
  exact original bytes before truncating at a decoded event boundary.
- PTY read chunking does not change the command output that is hashed.
- A process that writes continuously and ignores `TERM` still reaches its hard
  deadline and leaves a recorded timeout.
- A policy denial is stronger than an allow rule, and prompt text never widens
  a capability.

## Review triggers

Review this model before merging a change that:

- opens a network connection or listening socket;
- reads or uses a credential;
- implements file write, delete, git push or remote execution;
- sends workspace content to a model provider;
- changes event encoding, recovery, retention or migration;
- describes an event record as proof, authentic or tamper-proof.

Report a discovered vulnerability through `SECURITY.md`. Keep affected records
unchanged until a copy has been preserved for analysis.
