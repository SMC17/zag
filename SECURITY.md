# Security policy

zag executes programs, records terminal output and evaluates agent requests.
Treat a policy bypass, path escape, command injection, unauthorised network use,
credential disclosure or undetected record change as a security issue.

## Report a vulnerability

Do not open a public issue with exploit details. [Report the vulnerability
privately](https://github.com/SMC17/zag/security/advisories/new). If that form is
not available, contact [the repository owner](https://github.com/SMC17) without
including sensitive details, and ask for a private reporting channel.

Include:

- the affected commit and platform;
- the smallest steps that reproduce the issue;
- the result you expected and the result you saw;
- the impact and any known workaround.

Remove tokens, credentials and personal workspace data from the report. Keep a
damaged `.workspace/events.jsonl` file unchanged if it is part of the evidence.
`zag recover` prints a plan without changing the file. Its approval mode copies
the exact original bytes under `.workspace/recovery/` before truncating, but do
not approve that step until the incident reviewer agrees. The implemented
boundary and known residual risks are in `docs/threat-model.md`.

## Supported versions

Until the first stable release, security fixes target the current `main`
branch. Older snapshots may not receive a separate patch.

## Integrity boundary

The event log's hash chain detects a change relative to the chain it contains.
It does not prove who wrote the log, and an attacker who can replace the whole
file can compute a new chain. Independent signed checkpoints are planned and
must exist before the log is described as tamper-proof.
