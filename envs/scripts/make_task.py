"""Assemble a Zig 0.15 -> 0.16 port task in Harbor format from its parts.

usage: python3 -I envs/scripts/make_task.py SPEC.json

SPEC keys (paths relative to the spec file):
  name          task directory name under envs/ (also sunlitmoon/<name>)
  lib           library module name; the agent's library is src/<lib>.zig
  description   one line for task.toml
  app           directory with the Zig 0.15.2 starting project (build.zig, src/, tests/, ...)
  solution      directory with the Zig 0.16.0 reference port (files copied over /app)
  hidden_test   Zig test file importing @import("<lib>")
  cases         directory of case directories (setup.sh?, args?, stdout, exit, stderr?)
  instruction   markdown file given to the agent
  hacks         directory of task-specific hack scripts (each with '# expect: 0')
  readme        markdown file: the task README (what it exercises, why it is hard)
  post_build    optional: shell script run in the agent's built tree after `zig build`; non-zero fails
  lib_pre       optional: arguments placed before -M<lib>= when the verifier compiles the
                agent's library, e.g. '-I "$W/agent/c" "$W/agent"/c/*.c' for C sources

The verifier (template/test.sh), Dockerfiles and the generic hacks (write the reward,
fake toolchain) are shared, so every task gets the same defences as zig-016-port.
"""
import json, pathlib, shutil, sys

ENVS = pathlib.Path(__file__).resolve().parent.parent
TEMPLATE = pathlib.Path(__file__).resolve().parent / "template"

TASK_TOML = """schema_version = "1.4"

[[artifacts]]
source = "/app"
exclude = [".zig-cache", "zig-out"]

[task]
name = "sunlitmoon/{name}"
version = "0.1.0"
description = "{description}"
keywords = ["zig", "migration", "systems", "software-engineering"]
[[task.authors]]
name = "SMC17"

[metadata]
difficulty = "medium"
category = "software-engineering"

[verifier]
timeout_sec = 900.0
environment_mode = "separate"
network_mode = "no-network"

[agent]
timeout_sec = 1800.0

[environment]
network_mode = "public"
build_timeout_sec = 900.0
os = "linux"
"""

SOLVE = """#!/bin/bash
# Reference port to Zig 0.16.0. Proves the task is solvable within the image.
set -eu
cp -r /solution/files/. /app/
cd /app && zig build test && zig build
"""

SOUNDNESS = """# Why a 1 on this task means the port was done

This task uses the shared verifier (`envs/scripts/template/test.sh`). Its full argument is in
[`zig-016-port/SOUNDNESS.md`](../zig-016-port/SOUNDNESS.md), and it applies here unchanged:

1. Hidden behavioural tests (`tests/hidden/hidden_test.zig`), compiled by the verifier
   against the agent's `src/{lib}.zig`. The agent's `build.zig` is not used for this step.
2. The CLI, built by the verifier from `src/main.zig`, run on {ncases} hidden cases. Expected
   stdout, stderr and exit codes come from an independent Python implementation
   (`gen_cases.py` in this directory), not from the reference port.
3. `zig build` and `zig build test` from the agent's own build graph, run last, as `nobody`,
   in a copy, with `/tests` read-only. Only the exit codes count.

The verifier runs in a separate container with no network, and the reward is binary.

## Audit controls

`python3 -I ../scripts/soundness.py {name}` runs, through Harbor:

| Control | Expected |
| --- | ---: |
| oracle (reference port) | 1 |
| nop | 0 |
{hack_rows}

## Not defended (open)

- **Memorisation of the hidden files**, which are public in this repository. Rotate them
  before any held-out use.
- **Behaviour the hidden suite does not exercise.**
"""


def main():
    spec_path = pathlib.Path(sys.argv[1]).resolve()
    base = spec_path.parent
    spec = json.loads(spec_path.read_text())
    p = lambda k: (base / spec[k]).resolve()
    out = ENVS / spec["name"]
    if out.exists():
        shutil.rmtree(out)
    (out / "environment").mkdir(parents=True)
    ignore = shutil.ignore_patterns(".zig-cache", "zig-out")
    shutil.copytree(p("app"), out / "environment" / "app", ignore=ignore)
    shutil.copy(TEMPLATE / "Dockerfile.agent", out / "environment" / "Dockerfile")
    (out / "tests" / "hidden").mkdir(parents=True)
    shutil.copy(TEMPLATE / "Dockerfile.verifier", out / "tests" / "Dockerfile")
    t = (TEMPLATE / "test.sh").read_text().replace("@TASK@", spec["name"]).replace("@LIB@", spec["lib"])
    # Extra compiler arguments for the library module (C include paths and C sources), which
    # must come right before -M<lib>=... on the command line.
    t = t.replace("@LIB_PRE@", spec.get("lib_pre", ""))
    (out / "tests" / "test.sh").write_text(t)
    (out / "tests" / "test.sh").chmod(0o755)
    shutil.copy(p("hidden_test"), out / "tests" / "hidden" / "hidden_test.zig")
    shutil.copytree(p("cases"), out / "tests" / "hidden" / "cases")
    (out / "solution").mkdir()
    shutil.copytree(p("solution"), out / "solution" / "files", ignore=ignore)
    (out / "solution" / "solve.sh").write_text(SOLVE)
    (out / "solution" / "solve.sh").chmod(0o755)
    shutil.copy(p("instruction"), out / "instruction.md")
    shutil.copy(p("readme"), out / "README.md")
    if "post_build" in spec:
        shutil.copy(p("post_build"), out / "tests" / "hidden" / "post_build.sh")
    if "gen_cases" in spec:
        shutil.copy(p("gen_cases"), out / "gen_cases.py")
    hacks = out / "audit" / "hacks"
    hacks.mkdir(parents=True)
    for h in sorted((TEMPLATE / "hacks").glob("*.sh")) + sorted(p("hacks").glob("*.sh")):
        shutil.copy(h, hacks / h.name)
        (hacks / h.name).chmod(0o755)
    rows = []
    for h in sorted(hacks.glob("*.sh")):
        lines = h.read_text().splitlines()
        what = next((l.split("--", 1)[1].strip() for l in lines if l.startswith("# expect:") and "--" in l), "")
        rows.append(f"| `{h.stem}`: {what} | 0 |")
    ncases = len([d for d in p("cases").iterdir() if d.is_dir()])
    (out / "SOUNDNESS.md").write_text(SOUNDNESS.format(lib=spec["lib"], name=spec["name"], ncases=ncases, hack_rows="\n".join(rows)))
    (out / "task.toml").write_text(TASK_TOML.format(name=spec["name"], description=spec["description"]))
    print(f"wrote {out.relative_to(ENVS.parent)}: {ncases} cases, {len(rows)} hacks")


if __name__ == "__main__":
    main()
