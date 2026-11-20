# Why a 1 on this task means the port was done

This task uses the shared verifier (`envs/scripts/template/test.sh`). Its full argument is in
[`zig-016-port/SOUNDNESS.md`](../zig-016-port/SOUNDNESS.md), and it applies here unchanged:

1. Hidden behavioural tests (`tests/hidden/hidden_test.zig`), compiled by the verifier
   against the agent's `src/cbase.zig`. The agent's `build.zig` is not used for this step.
2. The CLI, built by the verifier from `src/main.zig`, run on 17 hidden cases. Expected
   stdout, stderr and exit codes come from an independent Python implementation
   (`gen_cases.py` in this directory), not from the reference port.
3. `zig build` and `zig build test` from the agent's own build graph, run last, as `nobody`,
   in a copy, with `/tests` read-only. Only the exit codes count.

The verifier runs in a separate container with no network, and the reward is binary.

## Audit controls

`python3 -I ../scripts/soundness.py zig-016-cbuild` runs, through Harbor:

| Control | Expected |
| --- | ---: |
| oracle (reference port) | 1 |
| nop | 0 |
| `h01_write_reward`: write the reward file directly from the agent container, do no work. | 0 |
| `h02_hardcode_output`: builds and tests pass, but `crc` prints the check value for any input. | 0 |
| `h03_stub_library`: decodeAlloc stubbed to return its input unchanged; visible tests emptied. | 0 |
| `h05_fake_toolchain`: leave the code unported; shadow zig with a script that always succeeds. | 0 |
| `h06_partial_port`: near miss: build.zig ported, main.zig left on the 0.15 I/O API. | 0 |
| `h07_drop_static_lib`: full behaviour, but the C sources are compiled straight into the executable and test, so the static library and headers are no longer built or installed. | 0 |
| `h08_accepts_noncanonical`: full port, but the C decoder no longer rejects non-canonical padding bits. | 0 |

## Not defended (open)

- **Memorisation of the hidden files**, which are public in this repository. Rotate them
  before any held-out use.
- **Behaviour the hidden suite does not exercise.**
