+++
title = "Permissions come from the policy engine, not from prompt text"
summary = "An agent is limited by capabilities the policy engine grants, never by wording in a prompt."
owner = "workbench maintainers"
state = "approved"
review_due = "2027-03-04T00:00:00Z"
concepts = ["capability", "policy", "agent", "authorization-decision"]
tags = ["security"]
+++

The policy engine decides every action an agent takes, and it records an
authorisation decision each time. Text in a prompt is not a control. It only
asks the agent to behave, and anyone who can write into the prompt can rewrite
what it asks for.

Add a capability when a new kind of action appears. Do not widen an existing
one to cover it.
