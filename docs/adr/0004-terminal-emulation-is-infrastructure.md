# 4. Terminal emulation is infrastructure; the workspace model is the product

Date: 2026-09-04
Status: accepted

## The question

Should the workbench write its own terminal emulator, or use one?

## The decision

Use one. The escape-sequence parser sits behind a seam so that libghostty-vt can
replace the built-in one without disturbing anything above it.

The built-in parser exists so the system is complete today: it drives the
screen, the shell integration and the tests, and it makes no claim to be a full
terminal.

## Why

Terminal emulation is well specified, hard to get right, and identical for
everyone. It is not where a product is won. The block model, the event stream,
the policy engine and the standards control plane are where it is won.

## What follows

- `src/terminal/vt.zig` says plainly what it is and what it is not.
- Nothing above the seam depends on which parser is behind it.
- The screen is a view. The log is the record.
