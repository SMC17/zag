# If something here is wrong

This page is for anyone affected by work done with zag. The page is written for
people who have never used it. You can read it without an account and without
knowing the tool.

## What this tool does, in one paragraph

zag is a terminal that records what happens in it. A person runs commands in a
folder on their own computer. A model can run them too, under rules that person
wrote. Everything it does goes into a file in that folder, including the things
it was refused. Anything sent to a model is sent because the person wrote a
setting saying so.

## If a change to your work looks wrong

Ask the person who ran it for the record. The record is a plain text file at
`.workspace/events.jsonl`, in the folder they were working in. These commands
read it:

```
zag events .workspace/events.jsonl   # everything that happened, as a tree
zag why .workspace/events.jsonl      # what a failure depended on
zag history "status:failed"          # search what was run
```

The record says who ran each thing, when, what the rules allowed, and what was
refused. An edit to it shows up as an edit, so what it says is what happened.

A person who keeps the record to themselves is making their own choice. zag
holds no copy elsewhere and can compel nobody.

## If a model was involved

The record names the provider and the model for each request. It also names every action
the model asked for, with what the rules decided. A model here does only what
the person's own rules allow, and the rules stay beyond its reach. So if a model
did something that surprises you, the question is which rule allowed it.
`zag policy` prints those rules in words.

## To raise it with the people who make zag

Open an issue on the repository. You do not need to know Zig or to have used the
tool. Say what happened, and say what you expected instead. Where the problem
touches private work belonging to someone else, describe its shape and leave
their record out.

For anything that looks like a security fault, `SECURITY.md` says how to report
it privately instead.

## What we can and cannot do about it

We can change the tool. We can narrow a rule that was too broad. We can make a
refusal clearer. We can make the record say something it was leaving out. Each
of those has happened because somebody told us.

Three things stay beyond us. We cannot undo a change on another person's
computer. We cannot get their record for you. We cannot settle a disagreement
about their work. zag runs on their machine, under their rules, and keeps
nothing centrally. The person who ran it is the one who can answer for it.

## What this page does not promise

It promises no response time, no appeal, and nobody on call. A small number of
people make this tool in the open. What it promises is a written route, a record
that exists and can be read, and a page that says plainly where the route ends.
