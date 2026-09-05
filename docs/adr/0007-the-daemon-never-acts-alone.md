# 7. The daemon never acts alone

Date: 2026-09-05
Status: accepted

## The question

`zagd` holds a workspace open with no person watching it. It can read the log,
fold it into blocks, read the knowledge base and see a workflow. Should it also
run the workflow?

## The decision

No. The daemon opens a workspace, verifies the log, reports what it found, and
says what each step of a workflow would need. It stops there. A step runs when a
person, or a client acting for a person, decides it.

## Why

Every other control in this product assumes a decision point. An agent
proposes, the policy decides, and a person decides what the policy sends to
them. A headless process that could run steps on its own removes that point. It
would also be the easiest part of the system to misuse: nobody is watching it,
and it holds a workspace open for hours.

The dry run is still worth having. It answers the question a person actually
asks before they start: what will this need, and which steps will stop and wait
for me?

## What follows

- `Service.planWorkflow` returns a decision for each step and the list of steps
  waiting on a person. It executes nothing.
- The report says "may run" and "would be denied", never "ran" and "failed",
  because a report that reads like a result would be a false one.
- Running a command is a separate call, `Service.runCommand`. A client makes
  that call for a person who asked for it.
