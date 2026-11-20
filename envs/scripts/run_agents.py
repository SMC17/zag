"""Measure frontier pass rates on every task in envs/, through Harbor.

usage: python3 -I envs/scripts/run_agents.py AGENT [--model M] [--attempts K] [--tasks t1,t2]
                                             [--agent-kwarg k=v ...] [--env K=V ...] [--out FILE]

AGENT is a Harbor agent name (codex, antigravity-cli, claude-code, ...) or an import path.
Each task runs K attempts. The images are built first with plain `docker build`, because cold
`docker compose build` can hang on this machine. A trial counts toward the pass rate only if
the agent actually ran (see passrate.py), so a usage limit or an auth failure shows up as
"invalid", never as a 0.

Writes a JSON report (default: jobs/passrates-<agent>-<time>.json) and prints a table.
"""
import argparse, json, os, pathlib, subprocess, sys, time

ENVS = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import passrate  # noqa: E402
from soundness import prebuild  # noqa: E402


def tasks_in(envs: pathlib.Path):
    return sorted(p.name for p in envs.iterdir() if (p / "task.toml").exists())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("agent")
    ap.add_argument("--model")
    ap.add_argument("--attempts", type=int, default=3)
    ap.add_argument("--concurrency", type=int, default=3)
    ap.add_argument("--tasks")
    ap.add_argument("--agent-kwarg", action="append", default=[])
    ap.add_argument("--env", action="append", default=[], help="K=V set for the harbor process")
    ap.add_argument("--out")
    a = ap.parse_args()

    tasks = a.tasks.split(",") if a.tasks else tasks_in(ENVS)
    stamp = time.strftime("%Y%m%dT%H%M%S")
    label = a.agent.replace("/", "_").replace(":", "_")
    root = ENVS / "jobs" / f"passrates-{label}-{stamp}"
    root.mkdir(parents=True)
    env = dict(os.environ)
    for kv in a.env:
        k, _, v = kv.partition("=")
        env[k] = v

    report = {"agent": a.agent, "model": a.model, "attempts": a.attempts, "started": stamp,
              "harbor": subprocess.run(["harbor", "--version"], capture_output=True, text=True).stdout.strip(),
              "tasks": {}}
    for t in tasks:
        prebuild(ENVS / t)
        cmd = ["harbor", "run", "-p", str(ENVS / t), "-a", a.agent, "-k", str(a.attempts),
               "-n", str(a.concurrency), "-o", str(root / t)]
        if a.model:
            cmd += ["-m", a.model]
        for kw in a.agent_kwarg:
            cmd += ["--ak", kw]
        t0 = time.time()
        p = subprocess.run(cmd, capture_output=True, text=True, env=env)
        (root / f"{t}.log").write_text(p.stdout + p.stderr)
        rows = list(passrate.trial_rows(root / t))
        valid = [r for r in rows if r["valid"] and r["reward"] is not None]
        passed = sum(1 for r in valid if r["reward"] >= 1.0)
        report["tasks"][t] = {"trials": len(rows), "valid": len(valid), "passed": passed,
                              "pass_rate": passed / len(valid) if valid else None,
                              "invalid_reasons": sorted({r["blocked_by"] or r["exception"] for r in rows if not r["valid"]}),
                              "seconds": round(time.time() - t0)}
        r = report["tasks"][t]
        print(f"{t:22s} {passed}/{len(valid)} valid passed   ({len(rows) - len(valid)} invalid {r['invalid_reasons']})", flush=True)

    out = pathlib.Path(a.out) if a.out else ENVS / "jobs" / f"passrates-{label}-{stamp}.json"
    out.write_text(json.dumps(report, indent=2) + "\n")
    print(f"report: {out}")
    any_valid = any(v["valid"] for v in report["tasks"].values())
    sys.exit(0 if any_valid else 3)  # 3 = nothing measurable (e.g. agent blocked)


if __name__ == "__main__":
    main()
