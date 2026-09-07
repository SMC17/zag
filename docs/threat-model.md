# Threat model

This document describes the security boundary implemented by the current zag
substrate. It is a design review aid, not a claim that the unfinished product
is secure. Review it whenever a new executor, provider, network listener or
credential path is added.

## Scope and assets

The current scope is one local workspace, its child processes, the files under
`.workspace/`, the typed tool executors, and the model connectors and the gate
they pass through. The graphical client, the remote daemon interface and the
agent loop are not implemented and are not inside the evaluated boundary.

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
| T2 | A path uses `..` or a symlink to escape the workspace | Policy rejects lexical traversal and mismatched path roots; executors open every path through a workspace directory handle with `RESOLVE_BENEATH` and `RESOLVE_NO_MAGICLINKS`, so the kernel refuses an escaping path in any component; final event-log, object and recovery-evidence entries reject symbolic links | Only Linux enforces this. A build for another platform must refuse to execute rather than fall back to a lexical check |
| T3 | A command string gains unintended shell meaning | Agent tool requests carry argument vectors, and the executor passes the vector straight to `execve` with no shell; a test asserts that an argument containing a semicolon and a redirect creates no file. The interactive `zag run` command is explicitly a person-requested shell command | Keep the assertion as a release gate; a future convenience that joins a vector back into a line would undo it |
| T4 | An event is edited, reordered or appended by a stale writer | Content and chain hashes, strict decoding, prefix fingerprint and an exclusive writer lock | Signed external heads are needed to detect whole-log replacement, truncation or a hostile non-cooperating writer |
| T5 | A crash commits partial state | Objects are immutable and synchronized before events; incomplete and malformed log tails seal the workspace; recovery requires an explicit flag and preserves the exact original log first | Add power-loss fault injection, directory-entry durability checks and recovery exercises on real filesystems |
| T6 | A child prints OSC 133 bytes to forge a command boundary or status | Service-owned command wrappers use a random marker token that is removed before the command starts; control marks and parser states are bounded | Extend authenticated markers to interactive shell hooks; an ordinary `boundaryFromShell` value alone is not proof of origin |
| T7 | A child floods output or never exits | Captured output is bounded; deadlines use monotonic time and terminate the process group, escalating to `KILL` | Add operating-system CPU, memory, process-count and disk quotas |
| T8 | Terminal output discloses a secret | New event and object files use owner-only permissions where POSIX permissions exist | Add detection and redaction before output enters model context or diagnostic bundles |
| T12 | An agent spends a credential on a provider nobody chose | Asking a model needs three separate decisions — `model.infer` on the connector, `network.connect` on the host, `credentials.use` on the variable — all taken before the request is encoded. The credential is read only after its own decision allows it, is written into a header by the connector, and never enters a decision, a log, an error or a summary. A redirect is never followed, so a credential cannot be carried to a host the policy did not decide | Enforce the host at the socket, including name resolution and address changes; a host that resolves to an unexpected address is not yet caught |
| T12a | A model asks for a tool that would widen its own reach | A model's tool call becomes a typed request or nothing: an unknown name, arguments that do not fit the type, or an unknown enum value are all refused before any policy is consulted. The capability is taken from the request kind, never from the arguments, so a model that writes a capability into its own call is writing a field that does not exist. `infer` and `spawn_agent` are not offered at all, and a test asserts their absence rather than leaving it to whoever edits the list | Offer a way for a person to widen the offered set deliberately, with the widening recorded |
| T12b | An agent loop runs away, or repeats a refused call for ever | Four bounds, each reported separately: turns, tokens, a monotonic wall clock, and a repetition count over a fingerprint of the request's kind and resource. The fingerprint deliberately ignores fields nobody decides on, so varying a byte limit cannot defeat it | Bound the total work an agent may cause across runs, not only within one |
| T13 | A workspace policy file is written to widen permission | The file is never shown to a model and never consulted by one. Its fallback is not read from the file: an unparsable file allows nothing, and nothing more permissive is substituted. An unknown capability name refuses the whole file rather than dropping the rule, so a denial cannot be narrowed by a typo | Add a recorded event when the policy file changes, so a widening is visible in the log rather than only in the file |
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
- An executor refuses a decision whose capability or resource differs from the
  request it is handed.
- A command runs from its argument vector, with no shell interpreting it.
- A model request that the policy refuses is never encoded and never sent, and
  its credential is never read.
- A model's tool call becomes a typed request or nothing, and its capability
  comes from the request kind rather than from anything the model wrote.
- An agent run stops on every one of its four bounds, and says which.
- A command line rebuilt from an argument vector runs the same command the
  vector named.
- A policy file that does not parse allows nothing, and no other policy is put
  in its place.

## Review triggers

Review this model before merging a change that:

- opens a network connection or listening socket;
- reads or uses a credential;
- implements file write, delete, git push or remote execution;
- sends workspace content to a model provider;
- adds a connector, a wire format or a credential variable;
- adds a tool to the set a model is offered, or changes how a tool call is
  parsed into a typed request;
- joins an argument vector back into a command line;
- changes how the workspace policy file is read, or what its fallback is;
- changes event encoding, recovery, retention or migration;
- describes an event record as proof, authentic or tamper-proof.

Report a discovered vulnerability through `SECURITY.md`. Keep affected records
unchanged until a copy has been preserved for analysis.
