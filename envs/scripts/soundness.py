"""Verifier soundness audit for a Harbor task.

Runs, through the real Harbor CLI:
  - oracle  (the task's own solution)  -> must score 1
  - nop     (agent does nothing)       -> must score 0
  - every audit/hacks/*.sh             -> must score what its `# expect:` line says
Each hack runs as the oracle of a temporary copy of the task whose solution/solve.sh
is replaced by the hack, so it executes in the real agent image with /solution present.

A hack only counts if its own script completed (exit 0), so a "0" cannot come from a
hack that silently failed to do what it claims. Exit status is non-zero on any mismatch.

usage: python3 -I scripts/soundness.py TASK_DIR [--jobs N] [--out REPORT.json]
"""
import argparse, concurrent.futures as cf, json, pathlib, re, shutil, subprocess, sys, tempfile, time


def reward_of(job_dir: pathlib.Path):
    rs = list(job_dir.rglob("verifier/reward.txt"))
    if len(rs) != 1:
        return None
    try:
        return float(rs[0].read_text().strip())
    except ValueError:
        return None


SENTINEL = "__SOUNDNESS_HACK_COMPLETED__"


def solve_exit(job_dir: pathlib.Path):
    """0 if the hack ran to completion (its sentinel reached Harbor's oracle log), else 1.
    Harbor's oracle log holds stdout only, so the runner appends a sentinel echo that
    executes only if the hack script (set -e) exited 0."""
    logs = list(job_dir.rglob("agent/oracle.txt"))
    return 0 if any(SENTINEL in p.read_text(errors="replace") for p in logs) else 1


def run(task: pathlib.Path, agent: str, name: str, jobs_root: pathlib.Path, hack: pathlib.Path | None):
    work = pathlib.Path(tempfile.mkdtemp(prefix=f"snd-{name}-"))
    t = work / task.name
    shutil.copytree(task, t, ignore=shutil.ignore_patterns("audit", ".zig-cache", "zig-out"))
    if hack is not None:
        body = hack.read_text()
        (t / "solution" / "hack.sh").write_text(body)
        (t / "solution" / "solve.sh").write_text(
            f"#!/bin/bash\nbash /solution/hack.sh && echo {SENTINEL}\n")
        (t / "solution" / "solve.sh").chmod(0o755)
    out = jobs_root / name
    t0 = time.time()
    p = subprocess.run(["harbor", "run", "-p", str(t), "-a", agent, "-o", str(out)],
                       capture_output=True, text=True)
    (jobs_root / f"{name}.log").write_text(p.stdout + p.stderr)
    shutil.rmtree(work, ignore_errors=True)
    details = "\n".join(x.read_text() for x in out.rglob("verifier/details.txt"))
    return {"name": name, "agent": agent, "harbor_exit": p.returncode, "reward": reward_of(out),
            "solve_exit": solve_exit(out) if hack is not None else None,
            "seconds": round(time.time() - t0, 1), "verifier_details": details.strip().splitlines()[-3:]}


def prebuild(task: pathlib.Path):
    """Build the agent and verifier images with plain `docker build` first. On this machine
    (Docker 29 / OrbStack) a cold `docker compose build`, which Harbor runs, can hang
    indefinitely; a warm BuildKit cache avoids it, and failures here are reported clearly."""
    for ctx in (task / "environment", task / "tests"):
        if (ctx / "Dockerfile").exists():
            p = subprocess.run(["docker", "build", "-q", str(ctx)], capture_output=True, text=True, timeout=1800)
            if p.returncode != 0:
                sys.exit(f"docker build {ctx} failed:\n{p.stderr[-2000:]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("task"); ap.add_argument("--jobs", type=int, default=3)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    task = pathlib.Path(a.task).resolve()
    jobs_root = task.parent / "jobs" / f"soundness-{task.name}-{time.strftime('%Y%m%dT%H%M%S')}"
    jobs_root.mkdir(parents=True)
    prebuild(task)

    plan = [("oracle", "oracle", None, 1.0), ("nop", "nop", None, 0.0)]
    for h in sorted((task / "audit" / "hacks").glob("*.sh")):
        m = re.search(r"^# expect:\s*([0-9.]+)", h.read_text(), re.M)
        if not m:
            sys.exit(f"{h.name}: missing '# expect: <reward>' line")
        plan.append((h.stem, "oracle", h, float(m.group(1))))

    results = []
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        futs = {ex.submit(run, task, ag, n, jobs_root, h): (n, exp, h) for n, ag, h, exp in plan}
        for f in cf.as_completed(futs):
            n, exp, h = futs[f]
            r = f.result(); r["expected"] = exp
            ok = r["reward"] == exp
            if h is not None and r["solve_exit"] != 0:
                ok = False; r["note"] = "hack script itself failed; outcome proves nothing"
            r["ok"] = ok
            results.append(r)
            print(f"{'PASS' if ok else 'FAIL'}  {n:28s} reward={r['reward']} expected={exp} ({r['seconds']}s)", flush=True)

    results.sort(key=lambda r: r["name"])
    report = {"task": task.name, "harbor": subprocess.run(["harbor", "--version"], capture_output=True, text=True).stdout.strip(),
              "jobs_dir": str(jobs_root), "sound": all(r["ok"] for r in results), "results": results}
    out = pathlib.Path(a.out) if a.out else jobs_root / "soundness.json"
    out.write_text(json.dumps(report, indent=2) + "\n")
    print(f"\nsound={report['sound']}  report: {out}")
    sys.exit(0 if report["sound"] else 1)


if __name__ == "__main__":
    main()
