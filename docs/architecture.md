# Architecture

This document says how zag is put together, and why each part is where it is.

## The one decision everything else follows from

The workspace event stream owns the truth.

```
                        +--------------------------+
                        |       zag workbench      |
                        +-------------+------------+
                                      |
                    +-----------------v-----------------+
                    |          Workspace model          |
                    | tabs / splits / files / agents    |
                    | branches / worktrees / sessions   |
                    +-----------------+-----------------+
                                      |
                    +-----------------v-----------------+
                    |       Typed event stream          |
                    |                                   |
                    |  session_opened   tool_requested  |
                    |  command_submitted tool_finished  |
                    |  process_output   file_changed    |
                    |  command_finished approval_*      |
                    |  agent_started    git_changed     |
                    |  agent_message    diagnostic      |
                    +----+-----------+-----------+------+
                         |           |           |
              +----------v-+  +------v----+  +---v----------+
              | Terminal   |  |  Agents   |  | Editor       |
              | parser and |  |  policy   |  | content and  |
              | screen     |  |  runtime  |  | diagnostics  |
              +----------+-+  +------+----+  +---+----------+
                         |           |           |
                    +----v-----------v-----------v-----+
                    |      Durable local state         |
                    |  hash-chained log, content store |
                    +----------------------------------+
```

Everything becomes an event: a command, an agent action, a file change, an
approval, a git change, a diagnostic, a piece of evidence. The interface, the
block list and the execution graph are all folds over that stream.

This is what makes replay, crash recovery, remote attachment, audit trails and
deterministic agent context ordinary rather than special.

## The parts

### Events, and the log

`src/events/event.zig` holds the typed union. `src/events/log.zig` holds the
append-only log. Each entry carries the hash of its own content, and a chain
hash over the entry before it. An edit anywhere is therefore detectable, from
that point to the end of the log.

On disk it is one JSON object per line. A process that stops while writing
leaves an incomplete final line. Loading reports how many entries were
recovered and how many bytes were incomplete. It never guesses at the rest.

### Blocks

`src/workspace/block.zig` folds the log into blocks. A block is one unit of
work: a command with its output, an agent run, a tool call, a file change or an
approval. Each block carries its actor, its causal parent and its git context.
It also carries whether its boundary came from the shell or was inferred.

That last field matters. A figure computed from an inferred boundary is less
trustworthy than one computed from a shell mark. The model says which it is,
rather than averaging the two together.

### History

`src/workspace/history.zig` searches what happened, rather than searching a text
file. A shell history file cannot say which tests failed on this branch last
week, because it never recorded the branch, the result or the time. The event
log recorded all three, so history is a query over blocks:

    zag history "status:failed branch:main since:2026-09-01 zig build"

Bare words match the command text. A filter is written `field:value`. An unknown
filter name is reported rather than ignored, because a query that silently
matches everything is worse than one that fails.

Results are ranked by recency and repetition, and a command whose newest run
failed is pushed down. The weights are written in the code rather than tuned
invisibly, so the order can be explained to anyone who asks.

### The command editor

`src/editor/document.zig` treats the command line as an editing document, not as
a string. It is a piece table over two buffers: the original text, which never
changes, and the added text, which only grows. A cursor moves when the text
before it changes. A motion never splits a UTF-8 sequence. Undo groups by
intent, so a burst of typing undoes as one action, and an edit that came from an
agent never merges into a person's own typing.

A second reading of the same text names the parts of a command line: the
program, the options, the quoted arguments and the operators. An unclosed quote
is reported, because pressing enter on one hangs the shell.

### The terminal

`src/terminal` holds four things. There is the Digital Equipment Corporation
(DEC) escape-sequence state machine, with UTF-8 decoding. There is a screen with
scrollback and reflow. There is the operating system command (OSC) 133 shell
integration. And there is a real pseudoterminal, built from Linux system calls
with no C library.

Terminal emulation is infrastructure: well specified, hard to get right, and the
same for everyone. The parser sits behind a seam, so it can be replaced with
libghostty-vt without disturbing anything above it. What sits above it is the
part that is ours: the block model, the event stream and the workspace.

### Agents

`src/ai` holds the capability model, the policy engine, the approval prompts,
the typed tool requests and the runtime that joins them.

An agent proposes. The policy decides. A person decides what the policy sends
to them. Each step is recorded.

There is no free-form shell tool. No prompt can widen a permission either,
because permissions come from the policy alone.

### The workspace service and the daemon

`src/workspace/service.zig` is the workspace as a running service, with no user
interface attached. It owns the log on disk, the blocks folded from that log,
the knowledge base under `.workspace/`, and the policy engine that every
automated action passes through. `zagd` is a thin binary over it.

Two properties matter more than features. First, opening a workspace never
repairs a damaged log. A broken chain is reported, and the service then refuses
to append, because appending destroys the evidence of where the break is.
Second, the daemon never runs a workflow step on its own. It reports which steps
a person has to decide on, and stops there. A headless process that could act
alone would defeat the capability model.

### The knowledge base

`src/knowledge/base.zig` indexes `.workspace/` as the local-first replacement for
a hosted drive. It holds rules, prompts, workflows, notebooks, skills, server
definitions and environments. Each one is a Markdown file with front matter.
Every entry names an owner and a review date, which is what ISO 30401 asks for,
and a state, which is what ISO 10013 asks for. An agent is offered only the
knowledge that is approved and is not overdue.

An entry links to concepts rather than to words, so a search finds the entries
about a concept, not the ones that happen to use the term. This repository keeps
its own rules there, and `zag check` audits them like anything else.

### The standards control plane

`src/standards` holds the registry, the profiles, the crosswalks and the
evidence ledger. `standards/registry` holds the data.

For any artefact, the control plane answers five questions:

1. Which rules apply?
2. Which edition of each?
3. What evidence shows the rule was followed?
4. What was checked automatically?
5. What still needs a person?

The fifth question is the one that keeps the rest honest.

### Language, knowledge and metadata

`src/language` checks text against the plain-language rules, with profiles for
controlled English and easy-to-read material. `src/knowledge` holds the concept
system and publishes it. `src/metadata` holds the registry of every field that
crosses an interface.

These are not documentation aids. The agent runtime resolves a person's words
through the concept system. The event log uses the registered field names. The
test suite checks the approval prompts against the language rules.

## What is not built yet

- The graphical renderer. The accessibility tree it must publish is built, and
  is checked, so the renderer has a contract to meet.
- The graphical editor surface. The document model underneath it is built.
- The language-server client.
- The model providers. The runtime, the policy and the tool types are built.
- The network interface of the daemon. It is described in
  `schemas/openapi.json`, which is generated from the types the runtime uses.
  The daemon opens a workspace, verifies it, reports on it and plans a workflow.
  It does not yet listen on a socket.
- Windows and macOS pseudoterminals.

`zag doctor` prints this list from the code, so it cannot drift.
