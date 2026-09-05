# Plain language in this product

ISO 24495-1 says information is in plain language when the intended reader can
find what they need, understand it, and use it. It also says to judge that by
evaluating the text with readers, not by counting syllables.

This product applies both halves of that.

## Where the rules apply

They apply to the product, not only to the documentation:

- error messages,
- permission prompts,
- button and menu labels,
- status text,
- agent messages,
- command-line help,
- release notes,
- warnings,
- this repository's own documents.

The approval prompts are the clearest case. A prompt like this one is a defect:

> Agent requires elevated process execution capability for proposed operation.

The reader cannot tell what will run, against what, or what their choices mean.
The workbench generates this instead:

> Run rm -rf build/?
> The agent wants to run rm -rf build/ on this computer.
> This removes the build folder and everything inside it. You cannot undo it here.
> Files that are tracked by git can be restored from the repository.
>
> Allow once  ·  Allow here from now on  ·  Cancel

The prompt is built from the policy decision, so its words cannot drift from the
operation being approved. The test suite runs the plain-language checker over
every generated prompt.

## The rules the checker applies

Each rule has a code, and each one names the principle it serves.

| Code | What it finds |
| --- | --- |
| PL001 | A short form appears without being written out |
| PL002 | A sentence is longer than this reader should have to parse |
| PL003 | A paragraph holds more than the reader can scan |
| PL005 | An instruction hides who acts |
| PL006 | A light verb hides the action in a noun |
| PL007 | Four words in a row with no linking word |
| PL009 | A quantifier that leaves an instruction unactionable |
| PL010 | A condition runs on before the reader learns what to do |
| PL012 | The action appears at the end of the instruction |
| PL014 | The sentence opens without naming its subject |
| PL015 | A longer word where a shorter one means the same |
| PL016 | A phrase that can be shortened without losing meaning |
| PL018 | A label that does not say what happens |
| PL022 | An error message with no next step |
| PL024 | An internal code shown without an explanation |
| PL026 | A warning that does not say what could happen |
| PL028 | A request that does not name the operation and the thing it affects |
| PL030 | A placeholder that reached the reader |
| PL035 | Two or more negatives in one sentence |
| PL041 | A term we no longer use |
| PL050 | A figure of speech, for readers who should not have to decode one |
| DATE02 | A date or time that can be read two ways |
| UNIT03 | A unit that means more than one thing in prose |

Two profiles add their own rules. Controlled English (ASD-STE100) applies to
procedures and support material: short sentences, approved words, one
instruction at a time, no contractions. The easy-to-read profile applies to
material for readers who need short sentences and one idea at a time.

Neither profile applies everywhere. Controlled English would flatten a
scientific argument; easy-to-read rules would remove precision an expert reader
needs. The profile is chosen by audience and by kind of text.

## Who the reader is changes the answer

The same sentence can be fine for one reader and wrong for another. A limit
comes from the reader and the kind of text together:

- a developer working: 25 words a sentence,
- a person deciding during an incident: 18 words,
- a reader who needs easy-to-read material: 15 words,
- a button label: 6 words, whoever reads it.

Short forms work the same way. `ISO` needs no explanation for a developer or an
auditor. It needs one for a general reader, and the checker says so.

## What the checker does not do

It finds likely problems. It does not establish conformance with ISO 24495-1,
and every report it writes says so in those words.

The standard is met when the intended reader can find, understand and use the
information. Establishing that means putting the text in front of readers and
watching whether they can act on it. A score would only hide the difference.
