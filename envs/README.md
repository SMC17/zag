# envs

Agent tasks in [Harbor](https://github.com/laude-institute/harbor) format, each of which ships
with an adversarial check of its own verifier.

A task here is not finished when the reference solution passes. It is finished when
`scripts/soundness.py` shows, through the real Harbor CLI, that:

- the reference solution (`oracle`) scores 1;
- an agent that does nothing (`nop`) scores 0;
- every scripted reward hack in the task's `audit/hacks/` scores 0. Each hack counts only if
  the hack script itself completed, so a broken hack cannot pass as a defended one.

## Tasks

| Task | What the agent does | Verifier | Soundness | Frontier pass rate |
| --- | --- | --- | --- | --- |
| [`zig-016-port`](zig-016-port/) | Port a Zig 0.15.2 library and CLI to Zig 0.16.0 without changing behaviour | Separate container, no network, binary reward. Hidden tests, plus CLI expectations from an independent Python implementation | oracle 1, nop 0, 8/8 hacks 0 (2026-11-19, Harbor 0.26.0, aarch64). See [SOUNDNESS.md](zig-016-port/SOUNDNESS.md) | not yet measured |

## Run

```sh
uv tool install harbor                      # Harbor CLI; needs Docker
harbor lint zig-016-port
python3 -I scripts/soundness.py zig-016-port --jobs 3   # report: jobs/…/soundness.json
harbor run -p zig-016-port -a oracle
python3 -I scripts/passrate.py jobs/<job-dir>             # pass rate over trials where the agent actually ran
```

`passrate.py` excludes trials where the agent never acted, such as a usage limit, a missing
model name or a failed install. Harbor scores those as 0, which would make a task look harder
than it is.

The hidden cases are public in this repository, so this task works for development and
demonstration but not as a held-out benchmark. Regenerate them with a new seed
(`scripts/gen_cases.py`) before any use where memorisation matters.
