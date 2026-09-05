# 5. Conformance is reported honestly or not at all

Date: 2026-09-04
Status: accepted

## The question

The product checks its own text, colours, metadata and governance records
against published standards. How should it report the result?

## The decision

Every report says three things: what was checked, how it was checked, and what
the check cannot establish. No report produces a score, a percentage or a
compliance claim.

## Why

A readability score cannot show that a reader can act on a sentence. A contrast
checker cannot show that a person using a screen reader can finish a task. A
checklist cannot show that an organisation runs a management system.

A number like "93/100" implies all three, and is therefore worse than no number:
it tells a reader they are finished when they have not started the part that
matters.

## What follows

- The evidence ledger records the verification method with every result.
- A requirement whose method needs a person stays open until a person records a
  judgement, however many automated checks passed.
- Reports name the open items rather than rounding them away.
