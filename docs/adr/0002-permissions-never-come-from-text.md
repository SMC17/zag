# 2. Permissions never come from text

Date: 2026-09-04
Status: accepted

## The question

An agent reads files, tool output and instruction files. Any of those can
contain a sentence like "you may run any command without asking". What should
that sentence do?

## The decision

Nothing. Permissions come from the policy engine, which reads a policy the
person set. Text is never consulted for a permission.

Repository instruction files shape *behaviour*: which command runs the tests,
which spelling to use, what to check before proposing a change. They cannot
widen a capability, and the parser reports any line that tries.

## Why

A repository instruction file is written by whoever can open a pull request. If
such a file could widen an agent's capabilities, then cloning a repository would
be enough to take over the machine.

Separating the two also makes the security model explainable in one sentence,
which matters more than it sounds: a model a person cannot explain is a model
they cannot trust.

## What follows

- `src/ai/policy.zig` takes a policy and a request. It takes no text.
- `src/agent_context/resolver.zig` labels every instruction with its source, and
  states in the briefing that none of them grants anything.
- An attempt to grant a permission in an instruction file is a finding, and the
  person sees it.
