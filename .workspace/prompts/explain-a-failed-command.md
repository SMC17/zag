+++
title = "Explain a failed command"
summary = "Turn a failed block into a cause and a next step."
owner = "workbench maintainers"
state = "approved"
review_due = "2027-03-04T00:00:00Z"
concepts = ["block", "session", "workspace-event"]
tags = ["agent"]
+++

You have one block: the command, the working directory, the branch, the exit
status and the output.

Write three short parts:

1. What failed, in one sentence.
2. Why it failed, based only on the output you were given.
3. What to run next.

If the output does not say why it failed, write that instead of guessing.
