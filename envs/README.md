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

| Task | What the agent does | 0.16 changes it exercises | Soundness | Frontier pass rate |
| --- | --- | --- | --- | --- |
| [`zig-016-port`](zig-016-port/) | Port a ledger library + CLI | `std.Io` writers, `main(init)`, build API, `ArrayList` defaults | oracle 1, nop 0, 8/8 hacks 0 | not yet measured |
| [`zig-016-dirstat`](zig-016-dirstat/) | Port a directory-walking library + CLI | `std.Io.Dir`, `walk`/`next(io)`, `statFile(io, ...)`, test helpers | oracle 1, nop 0, 7/7 hacks 0 | not yet measured |
| [`zig-016-runlist`](zig-016-runlist/) | Port a command runner | `std.process.run(gpa, io, ...)`, renamed `Term` tags, `posix.SIG` | oracle 1, nop 0, 7/7 hacks 0 | not yet measured |
| [`zig-016-kvd`](zig-016-kvd/) | Port a TCP key-value server | `std.Io.net` listen/accept/streams, `trimLeft` → `trimStart`, `.empty` maps | oracle 1, nop 0, 7/7 hacks 0 | not yet measured |
| [`zig-016-cbuild`](zig-016-cbuild/) | Port a build that makes and links a C static library | module-level `addCSourceFiles`/`addIncludePath`/`linkLibrary`, `.link_libc` | oracle 1, nop 0, 7/7 hacks 0 | not yet measured |

Soundness was audited on 2026-11-19 with Harbor 0.26.0 on aarch64 (Docker on macOS). The x86_64 images have not been run.

All tasks are Harbor format, with a separate verifier container, no verifier network and a
binary reward. Every task ships its own `SOUNDNESS.md`. Each verifier has three checks:
1. Hidden unit tests, compiled by the verifier.
2. The CLI, built by the verifier, run on hidden cases. The expected outputs come from an
   independent Python implementation (`gen_cases.py` in each task).
3. The agent's own `zig build` and `zig build test`, run last, as `nobody`.

The four newer tasks are generated from `sources/<task>/` by `scripts/make_task.py`, using the
shared verifier in `scripts/template/`. Edit the sources and regenerate; don't edit the
generated directories by hand.

## Run

```sh
uv tool install harbor                      # Harbor CLI; needs Docker
harbor lint zig-016-port
python3 -I scripts/soundness.py zig-016-port --jobs 3   # report: jobs/…/soundness.json
harbor run -p zig-016-port -a oracle
python3 -I scripts/passrate.py jobs/<job-dir>             # pass rate over trials where the agent actually ran
python3 -I scripts/run_agents.py codex --model openai/<model> --env CODEX_FORCE_AUTH_JSON=1   # every task, 3 attempts
scripts/schedule_passrates.sh                             # same, as a daily launchd job until a run has valid trials
scripts/agy_token.sh && python3 -I scripts/run_agents.py agy_oauth:AgyOAuth --model gemini/claude-opus-4-6-thinking --env PYTHONPATH=$PWD/agents
```

`agents/agy_oauth.py` runs the Antigravity CLI with your own agy sign-in instead of an API key.
On Linux, agy reads its token from `~/.gemini/antigravity-cli/antigravity-oauth-token`.
`scripts/agy_token.sh` exports the token from the macOS keychain to a 0600 file on the host.
Individual-plan quotas are small: on 2026-11-20, three parallel Opus 4.6 trials used up the
weekly quota in about two minutes, so treat this as a smoke-test path, not a benchmark budget.

`passrate.py` excludes trials where the agent never acted, such as a usage limit, a missing
model name or a failed install. Harbor scores those as 0, which would make a task look harder
than it is.

The hidden cases are public in this repository, so this task works for development and
demonstration but not as a held-out benchmark. Regenerate them with a new seed
(`scripts/gen_cases.py`) before any use where memorisation matters.
