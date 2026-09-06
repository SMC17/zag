# Platform support

Last checked: 6 September 2026.

This matrix separates evidence that a target compiles from evidence that the
program runs correctly on that target. A cross-compile is not a support claim.

| Operating system | Architecture | Build evidence | Runtime evidence | Current status |
| --- | --- | --- | --- | --- |
| Linux | x86-64 | Debug and ReleaseSafe builds in the release gate | All automated tests run; the pseudoterminal command path and an interactive shell session run in tests | Development platform |
| macOS | ARM64 | ReleaseSafe cross-compile in continuous integration | No native test run; no macOS pseudoterminal implementation, and no terminal settings implementation | Compile-only evidence |
| Windows | x86-64 | ReleaseSafe cross-compile in continuous integration | No native test run; no ConPTY implementation, and no terminal settings implementation | Compile-only evidence |
| Other targets | Not specified | No release-gate build | No release-gate test | Not evaluated |

## What must happen before support expands

A target becomes supported only after all of the following evidence is
recorded for a named operating-system version and architecture:

- a native Debug and ReleaseSafe build;
- the full automated test suite on the target;
- the same terminal behavioural tests used on Linux;
- install, upgrade and rollback exercises;
- documented packaging, signing and vulnerability-update procedures;
- declared performance and resource budgets with repeatable measurements.

Until then, a successful cross-compile means only that Zig accepted the source
for that target. `zag doctor` reports terminal availability in the running
binary.

`zag term` needs two things from the operating system: a pseudoterminal, and
control of the settings on the terminal it was launched from. Both are written
with Linux system calls today. On another platform the calls report that they
are unsupported, which is why the source still compiles there.
