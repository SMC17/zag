+++
title = "Run the tests before you propose a change"
summary = "Every proposed change carries a green test run behind it."
owner = "workbench maintainers"
state = "approved"
review_due = "2027-03-04T00:00:00Z"
concepts = ["workflow", "evidence"]
tags = ["quality"]
+++

Run `zig build check` before you propose a change. It runs the tests and then
audits this repository against its own standards profile.

If a check fails, fix the cause. Do not turn the check off. A check that is
turned off gives the same green result as a check that passes, and the two
mean opposite things.
