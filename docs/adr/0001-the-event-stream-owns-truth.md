# 1. The event stream owns the truth

Date: 2026-09-04
Status: accepted

## The question

What is the application's data model? A terminal makes it tempting to answer
"the screen grid", because that is what the user looks at.

## The decision

The typed workspace event stream is the data model. The screen, the block list,
the session tree and the execution graph are folds over it.

## Why

If the grid owns the truth, then history, replay, crash recovery, remote
attachment, audit and agent context each become a separate feature, and each one
can disagree with the others. If the stream owns the truth, all of them are one
fold away, and they cannot disagree because they are the same data.

The cost is that every state change must be expressible as a typed event. That
cost is worth paying, and it has already caught design errors: a state that
cannot be written as an event usually turns out to be a state nobody could
explain either.

## What follows

- The log is append-only and chained by hash.
- Nothing writes a block directly. Blocks are derived.
- A projection is rebuilt by replaying, so a bug in a projection cannot corrupt
  the record.
