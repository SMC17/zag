# Where zag stands, and what it has to beat

This document is the honest version. It says three things. What does zag do that
the other projects leave out? What do they do that zag still cannot? And in what
order do the gaps get closed? Read it if you are deciding whether to use zag
instead of the terminal you have.

Today, zag is behind these projects. Most of them are mature, and several are
excellent. This project intends to earn a narrower claim, and a harder one. A
terminal built as a recorded workspace is a better foundation than a terminal
built as a screen. That foundation can also be as fast as the fast ones.

## What "surpass" has to mean

A claim nobody can check says nothing. So the target is written as things a
reader can test:

1. **Throughput.** Parsing and screen updates measured in MiB per second, on a
   stated machine, in a stated build, with the harness in the repository.
   `zig build bench` prints them.
2. **Correctness under stress.** A recorded session that verifies end to end
   after a crash, a resize, a full scrollback and a program that never exits.
3. **Recall.** A question about last week's work answered from the record, with
   filters, rather than by grepping a history file.
4. **Governed automation.** An agent action that a local policy engine allowed
   or refused, with the decision written down and reviewable afterwards.
5. **Text a person can act on.** The build checks the product's own text against
   the plain-language rules. Each report names what the checker left open.

Numbers 3, 4 and 5 are where zag is already ahead. Numbers 1 and 2 are where the
established terminals are ahead, and where the work is.

## The field, in three groups

### Terminal emulators

Ghostty, Alacritty, Kitty, WezTerm, iTerm2, Windows Terminal and Tabby. These
render text, and most render it on the graphics card. They differ in platform,
configuration, tabs and splits, image protocols, font handling and how much they
do beyond the screen. Zellij sits beside them as a multiplexer.

Every one of them is ahead of zag on rendering, because zag has no renderer.
`zag term` hosts a shell inside the terminal a person already has, and records
what happens. That is a real product. It is still not a renderer.

Here is what zag adds. The session is a hash-chained event log. Close the shell
and the record is still there. Anyone can verify it, and it is searched by
result, branch and directory rather than by string.

### Block and workspace terminals

Warp and Wave Terminal. This is the closest group. Both group work into blocks;
both add assistance; both keep reusable knowledge somewhere.

zag differs in who owns the record. The event stream holds the truth, and every
view is a fold over it. Replay, audit, remote attachment and agent context are
then one mechanism rather than four features. The knowledge lives in
`.workspace/` in the repository, where a pull request can review it, rather than
in a service. zag is also a Zig program with no third-party dependency: the whole
product builds from the standard library.

Warp's client is closed source, so a person has no way to read what it records
or to prove what it sends. zag's record is a text file of JSON lines that anyone
can read, verify, and delete.

### Agent command-line tools and harnesses

Codex CLI, Gemini CLI, OpenCode, Aider, Cline, Goose, OpenHands, Continue,
Hermes Agent, cmux, Pi, term2 and Lacy. These run a model against a repository.
They differ in model support, editor integration, sandboxing and how much of the
loop they automate.

Almost all of them are ahead of zag on the thing they exist for: zag has no model
provider yet. The runtime, the typed tool requests, the approval prompts and the
policy engine are built and tested; the connection to a model is not.

Here is what zag adds. Permission comes from a policy, not from prompt text.
Every action an agent asks for names one capability and one resource. A local
policy engine decides it, and records an authorisation decision with a reason.
Asking a model to behave is only a request. Anyone who can write into the prompt
can rewrite it.

## What zag has today

Measured on this machine, in a release build, best of five runs
(`zig build bench` prints the current figures):

| Path | Throughput |
| --- | --- |
| Terminal stream into the screen, escapes and marks included | 75 MiB/s |
| Plain text into the screen | 48 MiB/s |
| Events appended and hash-chained | 350,000 events/s |
| Events verified end to end | 437,000 events/s |
| Blocks folded from the log | 1,190,000 blocks/s |
| History query over 20,000 blocks | 326 microseconds |
| Prose through the plain-language rules | 12 MiB/s |

Built, tested and audited by the build:

- A recorded interactive terminal. `zag term` runs the person's own shell with
  their own configuration, and records every command as a block.
- A hash-chained event log that survives a torn write and reports where it broke
  rather than repairing itself.
- Structured history: filters for result, actor, directory, branch, repository,
  exit status and time.
- A capability model and a local policy engine, with recorded decisions.
- A standards control plane over sixty-five standards, with evidence.
- Plain-language, terminology, metadata, accessibility and knowledge rules
  enforced by `zig build check`.

## What zag cannot do yet

This list is longer than the one above. It is the honest reason to keep using
the terminal you have for now.

- **No renderer.** No window, no graphics card, no font shaping, no ligatures, no
  images, no cursor styles. `zag term` needs a terminal to run inside.
- **No tabs, splits or panes.** One shell to a session.
- **No configuration file and no key bindings.** Nothing is customisable.
- **No model provider.** The agent runtime has nothing to call.
- **Linux only.** The pseudoterminal uses Linux system calls directly. macOS and
  Windows are not built.
- **No remote attachment.** The daemon opens, verifies, reports and plans. It
  does not listen on a socket.
- **No search index.** A history filter walks the blocks in memory.
- **No plugins, no scripting, no theme system.**
- **Unbounded memory in a long session.** The workspace service allocates from an
  arena that grows for the life of the process.

`zag doctor` prints this list from the code, so it cannot quietly go out of date.

## The order the gaps get closed in

Each step is small enough to finish, and ends in something a person can use. The
numbers in brackets are what has to be true before the step counts as done.

1. **Make the recorded terminal worth living in.** Configuration file, key
   bindings, and a block-aware status line. (A person can set their scrollback
   size and their keys without editing Zig.)
2. **Panes and tabs inside one recorded session.** (Two shells, one log, and the
   blocks say which pane they came from.)
3. **A model provider behind the existing runtime.** (An agent proposes a typed
   tool request. The policy engine decides it. The decision lands in the log.)
4. **A search index over blocks.** (A query over a million blocks stays under a
   millisecond.)
5. **macOS support.** (The pseudoterminal and the terminal settings work on
   both platforms, with the same tests passing.)
6. **The daemon listens.** (A second client attaches to a running workspace and
   catches up by reading the log.)
7. **A renderer.** (A window, a font, and the accessibility tree the checker
   already enforces.)

Steps 1 to 4 make zag the best recorded terminal. Steps 5 to 7 make it a
terminal a person can use as their only one.

## Where being second best is not acceptable

Three things have to be undeniable, because they are the reason for the project:

- **The record.** No other terminal can prove what happened in a session. zag's
  log verifies end to end, names where it broke, and never repairs itself
  quietly.
- **The security boundary.** No prompt text can widen a permission. Every agent
  action is a capability, a resource and a recorded decision.
- **The language.** Every message a person reads is checked by the build against
  the plain-language rules, and every report says what it did not establish.

Speed has to be good enough that nobody gives up any of that to get it. That is
the standard the benchmarks are held to.
