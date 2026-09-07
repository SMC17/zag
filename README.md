# zag

A workbench where people and agents do engineering work in one recorded
workspace.

zag is a terminal, a block model, an agent runtime and a standards control plane
in one Zig program. It fetches no package from the network: the whole thing
builds from the Zig standard library.

> Status: the substrate is built and tested, and an agent loop runs against it
> with every tool call decided separately. The graphical renderer and the editor
> surfaces are not written yet, and answers do not stream. `zag doctor` prints
> what this build can and cannot do, so the claim never runs ahead of the code.

## Why it is built this way

The usual mistake is to make the terminal grid the application's data model.
Then the interface owns the truth. Everything else — history, replay, audit,
remote attachment, agent context — has to be added back later. Each arrives as
its own feature, and each can disagree with the others.

Here the workspace event stream owns the truth:

- The interface does not own truth. It is a fold over the log.
- Agents do not own truth. They propose typed requests; the log records what
  happened. `zag ask` writes its whole run into the same log a command goes
  into, refusals included. An agent run and a shell command read the same way
  afterwards.
- The pseudoterminal does not own truth. It produces bytes, which become events.

Everything else follows from that. A block list, a session tab, an execution
graph, an audit trail and an agent's context are all views of the same events.

## What is in it

| Part | What it does |
| --- | --- |
| `src/events` | The typed event union, append-only hash chain, immutable content-addressed output store, the causal graph and the derived dependency graph |
| `src/workspace` | Blocks, sessions, workflows, structured history, and the workspace service |
| `src/editor` | The command line as an editing document, with undo that groups by intent |
| `src/terminal` | Escape-sequence parser, screen with scrollback, shell integration, real pseudoterminal, and the recording terminal |
| `src/ai` | Capabilities, the policy engine, the workspace policy file, approvals, typed tools and their executors, kernel-enforced path containment, the model connectors and the gate they pass through, the agent loop, attention selection, risk, impact, transparency, generated cards |
| `src/language` | The plain-language pass, with controlled-English and easy-to-read profiles |
| `src/knowledge` | The concept system, the thesaurus view, the published vocabulary and the workspace knowledge base |
| `src/metadata` | The registry that stops one field having four names |
| `src/standards` | The standards registry, conformance profiles, crosswalks and the evidence ledger |
| `src/content` | The typed content model and its publishers |
| `src/accessibility` | The semantic tree, contrast checks and the accessibility statement |
| `src/reports` | The metric registry and one report notation |

## Build it

```
zig build test     # run every test
zig build          # build the tools
zig build check    # run the tests, then audit this repository
zig build emit     # regenerate the schemas, the vocabulary and llms.txt
zig build bench -Doptimize=ReleaseFast   # measure the hot paths
```

You need Zig 0.16.0.

## Use it

```
zag term                       # a shell in a terminal that records what you do
zag doctor                     # what this build can and cannot do
zag policy                     # the policy in force, and where it was read from
zag providers                  # the model connectors, and which credentials are set
zag ask "why did that fail?"   # ask a model; it can use tools, one decision each
zag ask --stream "..."         # the same, printed as the answer arrives
zag secrets .env               # what would be taken out before anything is recorded
zag why .workspace/events.jsonl # what a failure depended on, and what it affected
zag run -- zig build test      # run a command and record it as a block
zag lint README.md             # check text against the plain-language rules
zag terms workspace            # what a word means here
zag standards                  # the standards in force, and their editions
zag check                      # audit this repository
zag card model                 # the model card, generated from the system
zag accessibility              # the accessibility statement and the themes
zag shell-hook bash            # the shell integration to add to your shell
zag workflow                   # this repository's own workflow, as a task graph
zag lifecycle                  # the lifecycle record, and what has not started
zag evidence                   # the conformance statement, from recorded evidence
zag history "status:failed zig" # search recorded work, not a text file
zag knowledge                  # the knowledge under .workspace/, and what is overdue
zag objects --root .           # audit stored command output without changing it
zag recover --root .           # inspect a damaged log and print a recovery plan
```

Settings live in `.workspace/settings.toml`. `zag emit` writes an example with
every value at its default. A setting this build cannot read is reported by
name, with what was found and what is being used instead, and the terminal
opens anyway — a mistake in that file never costs you a shell.

`zagd` holds a workspace open for clients, remote people and background agents:

```
zagd status                    # what is in the workspace
zagd verify                    # check the event log and stored command output
zagd plan                      # what each step of a workflow would need
zagd history "branch:main"     # the same search, without the tool
```

## What "standards-native" means here

Sixty-five standards, specifications and frameworks are recorded in
`standards/registry`. Each carries its edition, its status and how the workbench
enforces it. That record is not decoration: the build reads it, and refuses a
registry that enforces a withdrawn or draft edition.

The rules that a program can check are checked by the build:

- Plain-language rules over the product's own text, including this file and the
  tool's own help.
- Terminology rules over the product's own vocabulary. A circular definition or
  a term that means two things fails the build.
- Metadata rules over every field that crosses an interface.
- Contrast and target-size rules over the shipped themes and the accessibility
  tree the renderer must publish.
- Risk rules: a risk that claims to be mitigated must name a control that is
  enforced by code. An instruction to a model is not a control.
- Knowledge rules over `.workspace/`: an entry needs a named owner, a summary
  and a review date, and it cannot claim to be about a concept nobody defined.

The rules that a program cannot check are named as such, in every report:

- Whether a reader can find, understand and use the information.
- Whether a person using a screen reader can finish a task.
- Whether a risk treatment works in practice.

Those are settled by evaluating the product with people, and by audit. The
workbench never reports a score that implies otherwise. There is no
"ISO compliant: 93/100" anywhere in it, and there never will be.

## The security boundary

An agent asks; the local policy decides; the decision becomes a record.

```
request -> plan -> typed tool request -> policy decision
        -> (a person, when the policy says so) -> execution -> events
```

- There is no free-form shell tool. Each request names one capability and one
  resource.
- A path is normalised before policy matching, so textual `..` traversal is
  rejected. Beyond that, the executors open every file through a workspace
  directory handle with `RESOLVE_BENEATH` and `RESOLVE_NO_MAGICLINKS`, so the
  kernel refuses a symbolic link that leaves the workspace rather than the
  program noticing afterwards. Event logs, objects and recovery evidence also
  reject a symbolic link in the final path component.
- A command runs from its argument vector. There is no shell between the two,
  so there is nothing for a quotation mark to escape into.
- An executor spends the decision it was handed. It re-derives the capability
  and the resource from the request and refuses unless both match, so a decision
  to read one file cannot be spent on another.
- Asking a model is three permissions, not one: using a model, reaching that
  host, and spending that credential. All three are decided before the request
  is encoded, so a refused request is never built and a refused credential is
  never read.
- A model cannot name a capability. Its tool call becomes a typed request or
  nothing at all, and the capability comes from the request kind. Text can make
  a model ask for anything; asking is all it can do.
- Two tools are never offered to a model: asking another model, which would
  spend a credential on a request nobody read, and starting an agent, which
  would let it widen its own reach.
- The policy is a file the person writes, in `.workspace/policy.toml`. It is
  never shown to a model and never consulted by one. Run `zag policy` to read it
  in words. A file that does not parse allows nothing; nothing more permissive
  is substituted for it.
- An operation that cannot be undone stops and asks, in words that name the
  operation and its consequence.
- A repository instruction file shapes behaviour. It can never grant a
  capability, and the checker reports any line that tries.

## If something here is wrong

`docs/if-something-is-wrong.md` is for anyone affected by work done with zag,
whether or not they use it. It says how to read the record, how to raise a
problem, and what this project can and cannot do about it.

## Reading further

- `docs/architecture.md` — the event graph, the block model and the control plane
- `docs/standards-conformance.md` — which standards apply and how each is checked
- `docs/plain-language.md` — how ISO 24495 is applied, and what a checker cannot decide
- `docs/competitive-position.md` — how zag compares with other terminals, and what it cannot do yet
- `docs/roadmap.md` — what is complete, what happens next, and the evidence each milestone needs
- `docs/threat-model.md` — trust boundaries, implemented controls and residual security work
- `docs/platform-support.md` — compile evidence, runtime evidence and explicit platform exclusions
- `docs/adr/` — why the architecture is the way it is
- `AGENTS.md` — how to work in this repository
- `CONTRIBUTING.md` — how to prepare and check a change
- `SECURITY.md` — how to report a vulnerability without publishing exploit details
- `llms.txt` — the machine-readable index

## Licence

MIT. See `LICENSE`.
