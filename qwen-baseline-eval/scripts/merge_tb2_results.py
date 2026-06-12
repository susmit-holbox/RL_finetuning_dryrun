#!/usr/bin/env python3
"""
merge_tb2_results.py — combine an original Terminal-Bench 2.0 run with one or
more rerun jobs into a single, honest pass@1.

A rerun (run_tb2_bedrock.sh RERUN_RESULT=…) only re-evaluates the tasks that
failed/errored the first time. To get the true overall score you OVERLAY the
rerun's per-task rewards on top of the original: for every task the rerun
touched, its new reward wins; every untouched task keeps the original reward.

Usage:
    python scripts/merge_tb2_results.py BASE_result.json RERUN_result.json [RERUN2_result.json ...]

Later files override earlier ones task-by-task (so list reruns oldest→newest).
Prints a summary and writes merged_result_summary.json next to the BASE file.
"""
import json
import sys
from pathlib import Path


def task_rewards(result_path):
    """Return {bare_task_name: reward_float} for every scored task in a result.json.

    A task that errored (timeout/crash) with no reward bucket is recorded as 0.0
    so it counts against the denominator, exactly like the harbor metric does.
    """
    d = json.loads(Path(result_path).read_text())
    rewards = {}
    errored = set()

    def walk(o):
        if isinstance(o, dict):
            rs = o.get("reward_stats", {})
            if isinstance(rs, dict):
                for metric in rs.values():
                    if isinstance(metric, dict):
                        for k, tasks in metric.items():
                            try:
                                val = float(k)
                            except (TypeError, ValueError):
                                continue
                            for t in tasks:
                                rewards[t.split("__")[0]] = val
            es = o.get("exception_stats", {})
            if isinstance(es, dict):
                for tasks in es.values():
                    for t in tasks:
                        errored.add(t.split("__")[0])
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)

    walk(d)
    # Errored-but-unscored tasks count as 0.0.
    for name in errored:
        rewards.setdefault(name, 0.0)
    return rewards


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    base_path = sys.argv[1]
    rerun_paths = sys.argv[2:]

    merged = task_rewards(base_path)
    base_n = len(merged)
    base_pass = sum(1 for v in merged.values() if v >= 1.0)

    overrides = 0
    for rp in rerun_paths:
        for name, val in task_rewards(rp).items():
            if name in merged:
                overrides += 1
            merged[name] = val  # rerun wins

    total = len(merged)
    passed = sum(1 for v in merged.values() if v >= 1.0)
    failed = sorted(n for n, v in merged.items() if v < 1.0)

    print(f"Base run:    {base_pass}/{base_n} = {base_pass / base_n * 100:.1f}% pass@1")
    print(f"Reruns:      {len(rerun_paths)} file(s), {overrides} task rewards overlaid")
    print(f"MERGED:      {passed}/{total} = {passed / total * 100:.1f}% pass@1")
    print(f"Still failing ({len(failed)}):")
    for n in failed:
        print("  ", n)

    out = Path(base_path).parent / "merged_result_summary.json"
    out.write_text(json.dumps({
        "base_result": str(base_path),
        "rerun_results": list(rerun_paths),
        "base_pass": base_pass,
        "base_total": base_n,
        "merged_pass": passed,
        "merged_total": total,
        "merged_pass_at_1": round(passed / total, 4),
        "still_failing": failed,
    }, indent=2))
    print(f"\nWrote {out}")


if __name__ == "__main__":
    main()
