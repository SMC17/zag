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

The kernel holds file access inside the workspace. Paths are opened with
`RESOLVE_BENEATH` and `RESOLVE_NO_MAGICLINKS`. A symbolic link that leaves the
workspace is refused by the same component that would otherwise follow it. The
typed executors consume the decision they were handed, deriving the resource
from the request rather than from the caller. A command runs from its argument
vector, with no shell in between.

A model can be asked, through the policy. Five wire formats reach twenty-eight
connectors, ten of which run on this computer: Anthropic, OpenAI, Gemini, Ollama
and Hugging Face text generation. Every request passes the policy engine three
times before it is encoded. It asks to use a model, to reach the host, and to
spend the credential. A refused request stops there, before it is built. The
credential stays out of every decision, log, error and summary.

The policy is read from `.workspace/policy.toml`, written by the person whose
computer it is. A file that does not parse allows nothing; nothing more
permissive is put in its place.

The loop runs. A model is asked. Its tool calls become typed requests. Each one
is decided on its own and spent by an executor, and the results go back for the
next turn. A model is never offered a tool that would widen its own reach. It cannot
name a capability either, because the capability comes from the request kind.
Four separate bounds stop a run: turns, tokens, wall clock, and a model asking
for the same refused thing over and over. Each ending says which.

Two graphs are derived from the log rather than declared. The causal forest
answers "what led to this". A dependency graph adds the edges the log does not
write down, such as a file written here and read there. It answers "which of the
things I did could this be about", across sessions that caused nothing in each
other. Reachability over it is bitsets filled in one backwards pass. The
critical path is the chain that decided how long work took, rather than the sum
of everything in it.

What a model pays attention to is chosen by walking that graph from the event
being asked about, nearest first. Recency is only a tie-break.

The model path enters the record. `zag ask` writes a session, the agent that
started, every tool it asked for, what the policy decided, and what happened. It
is one causal tree, which `zag why` and the dependency graph read like any other
work. Until now it talked to a provider, ran tools and printed to the screen
without writing a single event.

Every event says who wrote it. The actor is derived from the account and the
machine name, so the same person is the same actor in every workspace they open.
The workbench acting on its own is a different actor of a different kind. Every
event used to carry sixteen zero bytes.

The record format is pinned by golden vectors: lines this program produced, kept
byte for byte. Tests assert that a stored line still hashes to its stored hash,
and that the encoder still produces those exact bytes. A renamed field now fails
a test instead of silently re-interpreting every record ever written.

Five things in this list were not true until recently, and are worth naming
because the tests were green throughout. The agent runtime obtained a decision
and discarded it, calling an executor that could not receive one. A second copy
of "what resource does this request touch" disagreed with the first, so the two
halves of the security model had never been tested against each other. A policy
rule scoped to hosts also allowed requests on any other kind of resource. And
`::1` never matched a rule that named it, because the host matcher split on the
first colon. Each now has a test that fails if the fix is removed.

Several things the record used to say were untrue, and are worth naming. A block
whose output arrived in pieces kept the last piece's hash beside the summed byte
count. It claimed a hash covering bytes the hash had never seen. A change of
directory was written as a repository moving, so a search by repository returned
directories. An agent run had no finish at all, so a workspace of completed runs
displayed every one of them as still going.

Two more were claims rather than records. The daemon said it held a workspace
open for clients, and it has no socket. `zag check` never loaded the requirements
register. Every profile naming a requirement was therefore checked against an
empty set, and eleven dangling identifiers went unnoticed.

The worst of them was in the recording terminal. The shell hooks read a variable
called `__zag_token` in four places, and every hook left it empty. Each boundary
mark therefore went out unauthenticated. An authenticated session rejected every
one, so `zag term` ended up recording no command boundaries.

The environment variable carrying that secret stayed set as well. Every program
the person ran inherited the token whose job is to stop programs forging
boundaries. The hooks now move it into a shell variable and unset it, and a test
fails if a hook stops doing either.

The records ledger called itself append-only and hash-chained while three
functions edited sealed records in place. A hold, its release and a disposal
changed fields that lay outside every hash, with no entry to mark them. Somebody
could lift a hold and destroy a record, leaving nothing behind. The ledger holds immutable
chained entries now, and a record's state is folded from them.

Deleting and pushing were refused as typed requests and reachable by running
the program, so the typed refusal was the one that could not run. An agent now
has to use the typed request, and may not run a shell at all.

These statements are covered by automated tests. They do not establish
power-loss survival on every filesystem, hostile tamper resistance, a safe
garbage collector, a complete terminal, a graphical product or organisational
certification. The wire formats are tested against recorded answers, and the
Anthropic connector has been called. The other addresses are each provider's
documented one, and `zag providers` says which is which.

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

Done. Files are opened relative to a workspace directory handle with
`RESOLVE_BENEATH`, so the kernel refuses a path that leaves the workspace. The
program no longer has to check afterwards. The typed executors are written, and
each one consumes the decision it was given, re-deriving the resource from the
request rather than trusting the caller. A command runs from its argument
vector, with no shell between the two. A model request passes the policy engine
three times before anything is encoded.

Still open:

- Connect to the address that was checked. Every address a provider's name
  resolves to is now classified before anything connects, and a public name
  answering with a loopback, link-local, private or reserved address refuses the
  request. What remains is that `std.http.Client` resolves the name a second
  time when it connects, so a name that answers correctly to the check and
  incorrectly to the connection is not caught. Closing that means owning the
  socket rather than handing a URL to a client.
- Review `docs/threat-model.md` with local users, malicious repositories,
  compromised child processes, model providers and remote clients in scope.
- Extend redaction to the remaining outputs. Command text, captured output and
  everything sent to a model are redacted today. Diagnostic bundles and
  generated security reports are not written by this build yet, and must be
  covered when they are.

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
- Read a model's answer as it arrives. Every connector waits for the whole
  reply, which is fine for a question and wrong for a long one.
- Run more than one tool call at a time. A turn that asks for four independent
  reads runs them one after another.
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
