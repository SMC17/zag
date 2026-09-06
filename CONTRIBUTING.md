# Contributing to zag

Thank you for improving zag. The repository favours small changes whose claims
can be checked from code, tests and recorded evidence.

## Before you start

- Use Zig 0.16.0.
- Add no third-party dependency. The project builds from the Zig standard
  library.
- Read `AGENTS.md` and the approved entries under `.workspace/rules/`.
- For a security issue, follow `SECURITY.md` instead of opening a public issue.

For a large behaviour or interface change, open an issue first. State the user
problem, the boundary that will change and the evidence that will show the
change works.

## Make the change

1. Create a focused branch from `main`.
2. Add a test that fails without the changed behaviour.
3. Keep new errors typed and pass allocators into the code that needs them.
4. Update the source of generated files, not only the generated output.
5. Run `zig build emit` when a schema, vocabulary or generated document changes.

Use the registered terms in product text. Run `zig build run -- terms <word>` if
a term is unclear.

## Check the change

Run:

```sh
zig build test --summary all
zig build check --summary all
zig build emit
```

Stage the generated outputs you intend to commit, run `zig build emit` once
more, then check that regeneration changed nothing in the working tree:

```sh
git diff --exit-code -- schemas vocab docs/glossary.md docs/risk-register.md llms.txt
```

Also run the relevant command by hand when a change affects terminal behaviour
or an error message.

## Open the pull request

Explain:

- what changed and why;
- which risk or failure it addresses;
- how you tested it;
- what remains outside the claim.

Do not describe the project as certified or fully compliant with a standard.
Name the profile, requirement and evidence that the change addresses.
