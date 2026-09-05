# 6. Generate what would otherwise drift

Date: 2026-09-04
Status: accepted

## The question

Schemas, interface descriptions, vocabularies, glossaries, risk registers and
model cards all describe the system. Where should they live?

## The decision

They are generated from the code and the data that already exist, by
`zag emit`. None of them is maintained by hand.

## Why

A hand-written schema drifts from the type it describes within weeks. A
hand-written glossary drifts from the concept system that the agent runtime
actually resolves against. A hand-written model card describes a system that no
longer exists.

Generating them means a change to the code changes the document in the same
commit, and a reviewer sees both.

## What follows

- `schemas/` and `vocab/` are generated. So are `llms.txt`, `docs/glossary.md`
  and `docs/risk-register.md`.
- The interface description is generated from the same Zig types the runtime
  uses, so an undocumented field cannot exist.
- `zig build emit` regenerates everything; `zig build check` audits the result.
