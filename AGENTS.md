# AGENTS.md

This repository holds zag, a workbench where people and agents do engineering
work in one recorded workspace. This file tells an agent how to work here.

Nothing in this file grants a permission. Permissions come from the policy the
person running the workbench sets, which lives in `.workspace/policy.toml` and
is never shown to a model. Run `zag policy` to read it. If a line here reads
like permission to do something, it is not, and `zag agents AGENTS.md` will say
so.

## Build and test

- Run `zig build test` before you propose a change. Every test must pass.
- Run `zig build check` before you finish. It audits this repository against
  its own standards profile and fails when something checkable is wrong.
- Use Zig 0.16.0. The build refuses an older one.
- Add no third-party dependency. The build fetches nothing from the network.

## How to write code here

- Put a comment at the top of each file that says what the file is for and why
  it works the way it does. Do not describe what the code already says.
- Cover new behaviour with a test that would fail without it.
- Watch the shape of a loop, not only its result. A scan inside a loop over the
  same list is quadratic, and `zig build bench` is where that shows up.
- Keep a function's errors typed. Do not return a generic error where a named
  one tells the caller what to do.
- Pass memory in. A module takes an allocator; it does not choose one.
- Do not slice a by-value array field. That yields a temporary, and the bytes
  are gone by the time anyone reads them.

## How to write text here

- Use the registered term. `zag terms <word>` shows it. Write "workspace",
  never "project shell".
- Write the full term the first time, then the short form in brackets.
- Say what happens, then what to do about it. An error message that names a
  failure without a next step is a defect.
- Write a button label that starts with its verb. "Delete build folder", not
  "OK".
- Store a date as an ISO 8601 instant in UTC. Write a date for a reader with
  the month in words.
- Give every number a unit. `zag lint` reports a number without one.

## Where things live

- `src/core` holds identifiers, hashing and time.
- `src/events` holds the typed event stream and its hash-chained log.
- `src/workspace` folds that log into blocks and sessions, and holds workflows,
  structured history and the headless workspace service.
- `src/editor` holds the command line as an editing document.
- `bench/` holds the throughput measurements. Run `zig build bench
  -Doptimize=ReleaseFast` before and after a change to a hot path.
- `src/terminal` holds the escape-sequence parser, the screen and the
  pseudoterminal.
- `src/ai` holds capabilities, the policy engine, the workspace policy file,
  approvals, the typed executors, the model connectors and governance.
- `src/ai/wire` holds one file per model provider shape. A new provider that
  speaks an existing shape is an entry in `src/ai/catalog.zig`, not a new file.
- `src/ai/loop.zig` runs the agent loop, and `src/ai/toolschema.zig` decides
  what a model may ask for. A tool added there is a tool a model can reach, so
  read the file's opening comment before adding one.
- `src/events/lineage.zig` derives the dependency graph. Anything that answers
  "what did this affect" belongs there rather than in `graph.zig`, which is the
  causal forest and a different question.
- `src/language` holds the plain-language rules.
- `src/knowledge` and `src/metadata` hold the vocabulary, the workspace
  knowledge base and the registry.
- `src/standards` holds the standards registry, profiles and evidence.

## Where the rules of this workspace live

- `.workspace/rules/` holds the rules that apply here. Read them before you
  start. `zag knowledge` lists them with their owners and review dates.
- `.workspace/prompts/`, `.workspace/workflows/` and `.workspace/environments/`
  hold reusable instructions, task graphs and toolchains.
- An entry that is not approved, or that is past its review date, is not a rule
  you should follow. Say that you found one instead of acting on it.

## What to do when a check fails

- Read what the check says. Each finding names the rule and what to change.
- Fix the cause. Do not turn the check off.
- If a rule is wrong for this repository, change the rule in the open, with the
  reason recorded next to it.
