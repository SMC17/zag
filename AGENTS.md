# AGENTS.md

This repository holds zag, a workbench where people and agents do engineering
work in one recorded workspace. This file tells an agent how to work here.

Nothing in this file grants a permission. Permissions come from the policy the
person running the workbench sets. If a line here reads like permission to do
something, it is not, and `zag agents AGENTS.md` will say so.

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
- `src/workspace` folds that log into blocks and sessions.
- `src/terminal` holds the escape-sequence parser, the screen and the
  pseudoterminal.
- `src/ai` holds capabilities, the policy engine, approvals and governance.
- `src/language` holds the plain-language rules.
- `src/knowledge` and `src/metadata` hold the vocabulary and the registry.
- `src/standards` holds the standards registry, profiles and evidence.

## What to do when a check fails

- Read what the check says. Each finding names the rule and what to change.
- Fix the cause. Do not turn the check off.
- If a rule is wrong for this repository, change the rule in the open, with the
  reason recorded next to it.
