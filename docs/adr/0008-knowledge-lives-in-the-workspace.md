# 8. Knowledge lives in the workspace, not in a service

Date: 2026-09-05
Status: accepted

## The question

Rules, prompts, workflows, notebooks, skills, server definitions and
environments have to live somewhere. A hosted drive is the usual answer.

## The decision

They live in `.workspace/` in the repository, as Markdown files with front
matter. The workbench indexes them; it does not own them.

## Why

Knowledge that lives in a service is hard to review, because it sits outside the
pull request. It cannot be branched with the code it describes. It disappears
when the account does. A rule about how to build this repository belongs beside
the repository.

Front matter carries what the standards ask for. ISO 30401 asks for an owner and
a review date. ISO 10013 asks for a state. An entry also links to concepts from
the product vocabulary, so a search finds the entries about a concept rather
than the entries that use a word.

## What follows

- An agent is offered only knowledge that is approved and is not overdue.
- `zag-audit check` audits `.workspace/` like anything else, and `zag-audit evidence`
  records what that audit established.
- This repository keeps its own rules there, so the product is its own first
  user.
