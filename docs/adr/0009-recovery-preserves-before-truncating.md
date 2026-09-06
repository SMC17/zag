# 9. Recovery preserves evidence before truncating

Date: 5 September 2026
Status: accepted

## The question

A torn write, malformed record or broken hash chain seals a workspace. How can
an operator resume work without letting an automatic repair erase the bytes
that explain the failure?

## The decision

Opening a workspace never repairs its event log. Recovery is a separate command
with two stages:

1. `zag recover` reads the log and prints the exact event and byte boundary it
   would keep. It changes nothing.
2. `zag recover --approve-truncate` locks and rechecks the source, copies every
   original byte to a file named by its BLAKE3-256 digest, rechecks the source
   again, truncates only at a boundary returned by the decoder, synchronizes the
   active file and verifies the result.

The evidence copy is created atomically and is never replaced. A stale plan or
conflicting evidence file stops recovery.

## Why

Automatic repair makes a damaged record look routine and destroys information
an incident reviewer needs. Re-encoding intact events would also substitute new
bytes for the original evidence. A plan-first operation makes the consequence
visible, while a content-addressed copy makes the exact pre-recovery source easy
to identify and verify.

## What follows

- A caller must provide approval explicitly; damaged content cannot imply it.
- A successful recovery resumes from the verified prefix, not from a guessed
  reconstruction of later events.
- Command-output objects are not deleted during recovery. `zag objects` reports
  which ones became unreferenced.
- Signed external checkpoints are still required to detect replacement or
  truncation of the whole local history by the same attacker.
