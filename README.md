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

zag shell-hook bash            # the shell integration to add to your shell
zag workflow                   # this repository's own workflow, as a task graph
zag history "status:failed zig" # search recorded work, not a text file
zag show "kind:command zig build"  # what that command actually printed
zag ask --resume               # carry on where the last run stopped
zag ask --children "..."       # let the run hand parts of the work to child agents
zag route                      # which model to use next, from what has worked here
zag route "fix the parser"     # the same, with the task in hand: a trained policy
zag trajectories               # every recorded agent run, scored
zag trajectories --json        # the same as JSON Lines, for training or eval
zag eval baseline.jsonl        # did a change help? paired, and honest about noise
zag judge                      # a model's second opinion on those runs, recorded
zag knowledge                  # the knowledge under .workspace/, and what is overdue
zag objects --root .           # audit stored command output without changing it
zag recover --root .           # inspect a damaged log and print a recovery plan
```

Settings live in `.workspace/settings.toml`. `zag-audit emit` writes an example with
every value at its default. A setting this build cannot read is reported by
name, with what was found and what is being used instead, and the terminal
opens anyway — a mistake in that file never costs you a shell.

## Ask a model

Two steps. Set a key, then write a policy:

```
export ANTHROPIC_API_KEY=...      # or any connector; run "zag providers"
zag policy --init                 # writes .workspace/policy.toml
zag ask "why did the build fail?"
```

`zag doctor` says which of the two is missing. If a key is set but no policy
allows reaching the provider, it names the host and tells you what to run —
that is the case where nothing is broken, nothing is misspelt, and the only
symptom is a refusal at the moment of asking.

With no policy file the built-in one is in force: it allows a model running on
your own computer and nothing else. So if you use Ollama, none of this is
needed.

### The policy file

`.workspace/policy.toml` is a list of rules. Each `[[rule]]` names **one**
effect — `allow`, `ask` or `deny` — and lists the capabilities it applies to:

```toml
[[rule]]
id = "ask-a-model"
allow = ["model.infer"]
because = "This workspace may ask a model questions."

[[rule]]
id = "reach-the-provider"
allow = ["network.connect"]
hosts = ["api.anthropic.com"]        # scoped: nowhere else may be reached
because = "The model runs there."

[[rule]]
id = "run-commands"
ask = ["process.execute"]            # stops for a person, each time
because = "A person decides each command before it runs."
```

The effect is the key, not a value: it is `allow = [...]`, not
`effect = "allow"`. `because` is required and is what a person is shown when a
decision is made. A rule may be scoped by `hosts`, `paths` or `agents`; an
unscoped rule applies to every resource of that capability.

Anything no rule allows is refused. A file with a mistake anywhere in it is
refused *whole* — nothing is granted by being written badly — and `zag policy`
says which rule and why.

Capabilities: `fs.read`, `fs.write`, `fs.delete`, `process.execute`,
`process.signal`, `network.connect`, `network.listen`, `git.read`,
`git.commit`, `git.push`, `credentials.use`, `credentials.read`, `mcp.invoke`,
`container.start`, `remote.execute`, `model.infer`, `agent.spawn`,
`knowledge.write`.

### Handing work to a child agent

One context doing everything is the limit an agent hits first. Reading six
files to find one answer spends six files' worth of context on a sentence, and
the sentence is all the work needed.

`zag ask --children` offers the run a `spawn_agent` tool. A child gets the
question and nothing else, does the reading in its own context, and hands back
its answer — not its transcript. The parent pays for the answer.

```
zag ask --children "why is the build slow?"
zag ask --together "..."             # a turn's children run at once
zag ask --children --depth 3 "..."   # deeper trees, if you mean it
```

It is off by default, and the policy has the last word: nothing spawns unless
a rule allows `agent.spawn`.

```toml
[[rule]]
id = "children"
allow = ["agent.spawn"]
because = "Reading in a child's context is cheaper than reading in mine."
```

Four bounds hold whatever the policy says, and they are why this could be
offered to a model at all. A child runs on the same policy engine as its
parent, so it can never decide anything the parent could not. Depth is
bounded, because a child that can spawn a child that can spawn is a fork bomb
with a language model in it. Fan-out is bounded per turn *and* over the run,
because ten turns of four is forty. And a child spends from what the parent has
left — half of the remaining turns and tokens — rather than a copy of the
budget, so four children in a row get a half, a quarter, an eighth.

`--together` is what makes a fan-out worth doing: four children reading four
parts of a repository take one child's wall clock rather than four. It is safe
because it takes authority away rather than granting any — children that run
side by side are narrowed to reading, so two of them cannot disagree about a
file, and one of them cannot start a fan-out inside the fan-out. The narrowing
is a deny rule appended to your policy, and the engine resolves deny over
allow, so there is no policy it could widen. A child that needs to run the
tests is a child to start on its own.

Each child's own work is in the record, under the parent, with its own agent
identifier and in the same session. `zag why` walks from one to the other.

### Two opinions of a run

`zag trajectories` scores every recorded run by arithmetic over the log: how it
ended, whether its actions worked, whether it went in circles. That score is
reproducible and can be checked by reading the log, and it is blind to the
question everybody actually asks. A run can end cleanly, make eight successful
tool calls, repeat nothing, and confidently say something false. Arithmetic
scores that run 1.0.

`zag judge` asks a model to read the same runs against a rubric and adds its
opinion next to the arithmetic — never instead of it. The arithmetic stays
underneath, because it does not drift and does not cost a request.

```
zag judge                      # judge every run not yet judged
zag judge --json               # the verdicts as JSON Lines
```

The useful output is not the judge's number. It is the disagreement: where the
two reach different conclusions is the shortlist of runs worth reading by hand,
and which way the gap goes tells you what to expect. A judge scoring above the
record usually means the run failed tidily; a judge scoring below it usually
means the run did every step correctly and answered the wrong question.

A trajectory contains file contents and command output — bytes an attacker may
have written. They are fenced with a token derived from the run itself, and any
occurrence of that token inside the quoted bytes is removed before fencing, so
text inside the fence cannot get out to where instructions are read from. The
judge is also told, in the instructions, that what is inside the fence is
evidence and not instruction.

Each verdict goes into the log as evidence: which model gave it, against which
rubric, with the whole thing addressed by hash. A run is judged once.

### Routing with the task in hand

`zag route` samples each model's record of success. It works, and it has one
blind spot: it has no idea what it is being asked. Every task is the same task
to it, so a model that reads code well and writes it badly gets one number that
averages the two.

`zag route "why does the build fail?"` trains a linear policy over named
features of the task — is it a question, does it ask for a change, does it name
a failure — by REINFORCE with a baseline on the rewards already in the log.
Same arms, same reward, same log; the only new thing is that the task is an
input.

Linear and few-featured on purpose. A workspace has tens or hundreds of runs,
not millions, and anything with more parameters than that fits the noise
perfectly and predicts nothing — invisibly. These weights are printed:

```
What it learned
  local/reader
    asks for an explanation      +0.71
    asks for a change            -0.63
```

The episodes were not produced by this policy, so reporting its training reward
as its expected reward would be measuring the behaviour that generated the
data. Instead the runs are split, the policy is trained on one part and
estimated on the other by self-normalised importance sampling, and the same
estimate is computed for always using the single best arm — which is what the
bandit converges to. The effective sample size is reported too, because
importance sampling can rest a mean over thirty runs on two of them.

`zag route` uses the trained policy only when it beats that incumbent on runs
it never saw, with enough held-back runs and enough effective sample for the
comparison to mean anything. Otherwise it says so and falls back to the bandit.

`zag-audit` is the second binary. It checks a repository against the standards
it claims to meet, and nothing it does is needed to record work:

```
zag-audit check                # audit this repository; the release gate
zag-audit lint README.md       # check text against the plain-language rules
zag-audit terms workspace      # what a word means here
zag-audit standards            # the standards in force, and their editions
zag-audit emit                 # regenerate the schemas, vocabularies and docs
zag-audit evidence             # the conformance statement, from recorded evidence
zag-audit card model           # the model card, generated from the system
zag-audit accessibility        # the accessibility statement and the themes
zag-audit lifecycle            # the lifecycle record, and what has not started
```

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
