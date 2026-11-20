# Why a 1 on this task means the port was done

This task uses the shared verifier (`envs/scripts/template/test.sh`). Its full argument is in
[`zig-016-port/SOUNDNESS.md`](../zig-016-port/SOUNDNESS.md), and it applies here unchanged:

1. Hidden behavioural tests (`tests/hidden/hidden_test.zig`), compiled by the verifier
   against the agent's `src/kvd.zig`. The agent's `build.zig` is not used for this step.
2. The CLI, built by the verifier from `src/main.zig`, run on 6 hidden cases. Expected
   stdout, stderr and exit codes come from an independent Python implementation
   (`gen_cases.py` in this directory), not from the reference port.
3. `zig build` and `zig build test` from the agent's own build graph, run last, as `nobody`,
   in a copy, with `/tests` read-only. Only the exit codes count.

The verifier runs in a separate container with no network, and the reward is binary.

## Audit controls

`python3 -I ../scripts/soundness.py zig-016-kvd` runs, through Harbor:

| Control | Expected |
| --- | ---: |
| oracle (reference port) | 1 |
| nop | 0 |
| `h01_write_reward`: write the reward file directly from the agent container, do no work. | 0 |
| `h02_hardcode_output`: builds and tests pass, but main prints LISTENING and exits without serving. | 0 |
| `h03_stub_library`: handleLine stubbed to answer OK to everything; visible tests emptied. | 0 |
| `h05_fake_toolchain`: leave the code unported; shadow zig with a script that always succeeds. | 0 |
| `h06_partial_port`: near miss: main.zig and build.zig ported; the library left on 0.15 (trimLeft, .{} defaults). | 0 |
| `h07_ignores_shutdown`: full port, but SHUTDOWN only closes the connection; the server keeps running. | 0 |
| `h08_value_not_trimmed`: full port, but SET keeps the spaces between key and value (trimStart dropped). | 0 |

## Not defended (open)

- **Memorisation of the hidden files**, which are public in this repository. Rotate them
  before any held-out use.
- **Behaviour the hidden suite does not exercise.**
