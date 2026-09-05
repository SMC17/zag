# Standards conformance

This document says which standards apply to zag, how each one is checked, and
what this repository does not establish.

Read the last section first if you are deciding whether to trust a claim.

## The registry

`standards/registry` holds 64 entries. Each one carries:

- the publishing body and the identifier,
- the edition and its status: published, draft, withdrawn, superseded, guidance
  or industry specification,
- how the workbench enforces it: mandatory, required in a profile, recommended,
  used only for export, or recorded for context,
- one sentence saying why it applies here.

`zag standards` prints the registry. The build validates it and fails when an
entry is inconsistent. Three checks matter most:

- A withdrawn or superseded edition may not be enforced. ISO/IEC 40500:2012
  adopted WCAG 2.0 and is withdrawn; the 2025 edition adopts WCAG 2.2. Both are
  recorded, and only the current one is enforced.
- A draft may not be enforced as though it were published. ISO 24495-4 is a
  draft, so it is recorded as guidance.
- An entry that says it was replaced must name the entry that replaced it.

## Profiles

Not every rule applies to every kind of work. `zag standards profiles` prints
the six profiles: default, enterprise, scientific, legal, controlled English and
easy to read.

A profile says which standards are in force, which language rules apply, and who
the reader is. It may also exclude a rule, and when it does, it must say why.
The scientific profile excludes the controlled-English vocabulary rule, because
controlled English removes the precision a scientific argument needs.

## What the build checks

`zig build check` runs the tests, then audits this repository. Every check below
runs in that gate.

### The checks

| Area | What is checked | Where |
| --- | --- | --- |
| Registry | Status, edition and enforcement are consistent | `src/standards/registry.zig` |
| Terminology | Definitions are not circular, not negative and not missing; no two concepts share a preferred term; the hierarchy has no loop | `src/knowledge/concepts.zig` |
| Thesaurus | Broader and narrower terms line up; related terms are mutual | `src/knowledge/thesaurus.zig` |
| Metadata | One canonical name for each field; no alias collides with another field's name; a quantity domain names a unit | `src/metadata/registry.zig` |
| Units and values | Every unit parses; money carries its currency and its minor units; every instant is a canonical UTC string | `src/interop` |
| Plain language | Product text, this file, and the tool's own help | `src/language/plain.zig` |
| Accessibility | Contrast for both themes; target size, names, focus order and live regions in the accessibility tree | `src/accessibility` |
| Risk | Every risk has an owner and a treatment; a treatment that claims to mitigate names a control enforced by code | `src/ai/risk.zig` |
| Impact | Excluded uses, affected groups, a route to challenge, and a mitigation for each harm | `src/ai/impact.zig` |
| Content | Procedures have steps; warnings state a consequence; figures have text alternatives; tables have headers | `src/content/ir.zig` |
| Instruction files | Any line that tries to grant a permission is reported | `src/agent_context/agents_md.zig` |

The table above has eleven rows on purpose: each row is one subsystem, and each
one fails the build on its own.

## What generated documents are checked against

The model card, the system card, the datasheet and the fact sheet are generated
from the system's own facts. Each is then checked against the CLeAR goals:
comparable, legible, actionable and robust. A card that is missing a required
section fails the check, because a card that cannot be set beside another card
has lost the point of the shape.

## What this repository does not establish

A program can find an undefined short form, a low contrast ratio, a missing
name, a circular definition or a risk without an owner. Here is what a program
cannot find out:

- whether the intended reader can find, understand and use the information;
- whether a person using a screen reader can complete a task;
- whether a risk treatment works when the system is under pressure;
- whether an organisation runs the management system it says it runs.

Those are settled by evaluating the product with people, and by audit. This
repository reports no conformance score, and claims certification against no
standard. The evidence ledger records what was checked, how, and by what tool or
reviewer. Where a rule needs a person, the report says the rule is open, and
names what is missing.

## The one obligation not yet met

`zag check` reports it on every run. A person affected by a change an agent
made, who does not use the workbench themselves, can raise it only through the
repository owner. That gap sits in the transparency obligations, where a reader
will find it.
