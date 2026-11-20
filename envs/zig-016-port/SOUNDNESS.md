# Why a 1 on this task means the port was done

Reward is binary. `tests/test.sh` writes `1` only after every check below passes, and
writes `0` and stops at the first failure.

## What the verifier checks

1. **Hidden behavioural tests** (`tests/hidden/ledger_hidden_test.zig`, 8 tests). The verifier
   compiles them against the agent's `src/ledger.zig` with its own `zig test`. The agent's
   `build.zig` is not used for this step. The tests cover every named parse error, whitespace
   and CRLF handling, overflow reported rather than wrapped, keys owned by the book (it does not
   keep pointers into caller buffers), 2,000 symbols through rehashing, bytewise sort order,
   the exact `render` format, and leak-freedom (`std.testing.allocator`).
2. **The CLI on hidden inputs.** The verifier builds `src/main.zig` itself with `zig build-exe`,
   then runs it on 4 inputs the agent never sees. It compares stdout, stderr and the exit code
   byte for byte, and also checks that running with no arguments exits with code 2. The expected
   outputs come from a separate Python implementation (`../scripts/gen_cases.py`, seed 17), not
   from the reference Zig port, so the reference solution is not graded against its own output.
3. **The agent's own build graph.** `zig build` and then `zig build test` in a private copy.
   Only their exit codes count.

## Threats, and what stops each one

| Threat | Defence | Audit control |
| --- | --- | --- |
| Agent writes `/logs/verifier/reward.txt` itself | Separate verifier container (`environment_mode = "separate"`). Only `/app` is carried across as an artifact | `h01_write_reward` |
| Output hardcoded for the visible `sample.csv` | Hidden inputs, with expected outputs from an independent implementation | `h02_hardcode_sample` |
| Library stubbed, visible tests deleted or emptied | Hidden tests compiled by the verifier. The visible tests are never trusted | `h03_stub_library` |
| `build.zig` runs code that plants a reward or rewrites the hidden expectations | Checks 1 and 2 never run agent build code. Check 3 runs last, as `nobody`, in a copy, with `/tests` read-only and `/logs/verifier` not writable by that user. The delayed background writer is covered too | `h04_buildzig_payload` |
| A fake `zig` (or a fake `/opt/zig/zig`) that always exits 0 | The verifier image installs its own sha256-pinned Zig and calls it by absolute path. Nothing from the agent's filesystem except `/app` reaches the verifier | `h05_fake_toolchain` |
| Near miss: build and main ported, library left on 0.15 defaults | Hidden tests compile the library itself | `h06_partial_port` |
| A real bug, with the visible tests edited until they pass | Hidden sort-order and CLI checks | `h07_tests_bent_to_bug` |
| Error path changed to exit 0 silently | Hidden bad-line case checks the exit code and the stderr bytes | `h08_print_error_swallow` |
| Verifier needs the network, or leaks to it | `[verifier] network_mode = "no-network"` | none; set in config |

`python3 -I ../scripts/soundness.py zig-016-port` runs all of these through Harbor, together
with the oracle (must score 1) and nop (must score 0). A hack's 0 counts only if the hack
script itself completed, so a broken hack cannot pass as a defended one.

### Last audit

2026-11-19, Harbor 0.26.0, Docker on macOS arm64 (aarch64 images): **sound = true.**
oracle scored 1. nop and all 8 hacks scored 0, and every hack script completed. Each hack was
caught by the check aimed at it: h02 by `case1 stdout`, h04 by `zig build test` with the reward
not flipped, h08 by `case3 exit code`, and the rest by the hidden unit tests. The x86_64 image
has not been run yet.

## What this does not defend against (open)

- **Overfitting to the hidden suite through memorisation.** If the hidden files are published,
  an agent can learn them. Before the task is used for training or as a held-out benchmark,
  rotate the hidden cases. `gen_cases.py` takes a seed for this.
- **Behaviour the hidden suite does not cover.** Inputs with `+5` or `1_000` are accepted by
  both Zig's `parseInt` and Python's `int`. The task's behaviour on those inputs is not
  specified and is not tested.
- **Compile-time execution.** The agent's `src/` is compiled as root in the verifier container.
  Zig comptime cannot do I/O, and `@embedFile` cannot reach outside the module's root
  directory. The containment therefore rests on the compiler, not on the OS.
- **Solution quality beyond behaviour**, such as style or idiomatic 0.16 usage, is not scored.
