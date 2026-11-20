"""Pass rate of a Harbor job, counting only trials where the agent actually ran.

A trial whose agent raised an exception before it could act (no model access, usage limit,
missing model name, install failure) scores 0 in Harbor's mean. That 0 says nothing about the
task. This script reads every trial in a job directory and sorts it into:

  valid     the agent ran to completion or timed out while working; its reward counts
  invalid   the agent failed for a reason outside the task (exception before any action)

usage: python3 -I envs/scripts/passrate.py JOB_DIR [--json]
"""
import json, pathlib, sys

# Exceptions that mean the agent was working on the task and ran out of time or turns.
# Their 0 is a real outcome.
COUNTS_AS_ATTEMPT = {"AgentTimeoutError"}
# Agent output lines that mean the model never answered.
BLOCKERS = ("usage limit", "usage_limit_exceeded", "authentication required",
            "not logged in", "model name is required", "rate limit", "quota")


def trial_rows(job: pathlib.Path):
    for res in sorted(job.rglob("result.json")):
        d = json.loads(res.read_text())
        if "trial_name" not in d and "task_name" not in d:
            continue  # job-level summary
        t = res.parent
        rf = t / "verifier" / "reward.txt"
        reward = float(rf.read_text().strip()) if rf.exists() else None
        exc = (d.get("exception_info") or {})
        etype = exc.get("exception_type")
        agent_text = " ".join(p.read_text(errors="replace")[-4000:] for p in (t / "agent").glob("*.txt"))
        blocked = next((b for b in BLOCKERS if b in (agent_text + str(exc.get("exception_message"))).lower()), None)
        valid = (etype is None or etype in COUNTS_AS_ATTEMPT) and blocked is None
        yield {"trial": t.name, "reward": reward, "exception": etype, "blocked_by": blocked, "valid": valid}


def main():
    job = pathlib.Path(sys.argv[1])
    rows = list(trial_rows(job))
    valid = [r for r in rows if r["valid"] and r["reward"] is not None]
    passed = sum(1 for r in valid if r["reward"] >= 1.0)
    summary = {"job": str(job), "trials": len(rows), "valid": len(valid), "passed": passed,
               "pass_rate": (passed / len(valid)) if valid else None, "rows": rows}
    if "--json" in sys.argv:
        print(json.dumps(summary, indent=2))
        return
    for r in rows:
        why = "" if r["valid"] else f"  INVALID ({r['blocked_by'] or r['exception']})"
        print(f"{r['trial']:28s} reward={r['reward']}{why}")
    pr = "n/a (no valid trials)" if summary["pass_rate"] is None else f"{passed}/{len(valid)}"
    print(f"\npass rate over valid trials: {pr}   ({len(rows) - len(valid)} invalid excluded)")


if __name__ == "__main__":
    main()
