# 3. No free-form shell tool

Date: 2026-09-04
Status: accepted

## The question

The simplest agent tool is one that takes a string and runs it in a shell. Should
the workbench offer one?

## The decision

No. Every action is a typed request that names exactly one capability and
exactly one resource. A command is an argument vector, not a string.

## Why

A free-form shell tool holds every capability at once, and the policy engine
cannot tell what a string will do before the shell splits it. Quoting bugs then
become security bugs: a file named `my file.txt` and a file named
`my; rm -rf ~; file.txt` are the same string to a shell.

With typed requests, the policy sees `process.execute` on `["rm","-rf","build"]`
and can decide it. A person sees the same thing in the approval prompt.

## The cost

Every new kind of action needs a type. That is the point: adding a capability
should be a visible change, reviewed like any other.
