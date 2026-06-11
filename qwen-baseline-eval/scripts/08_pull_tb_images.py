#!/usr/bin/env python3
"""
08_pull_tb_images.py — Pre-pull TerminalBench-2 task images from a public
ECR mirror and locally re-tag each image to the original Docker Hub name
declared in the task's task.toml so the Harbor harness finds it locally
without ever hitting Docker Hub.

Why this exists:
    Terminal-Bench 2.0 (the `terminal-bench@2.0` dataset) runs under the
    Harbor harness. Each task's task.toml names a PRE-BUILT image, e.g.
        docker_image = "alexgshaw/adaptive-rejection-sampler:20251031"
    Harbor pulls that image at run time. By default that's a Docker Hub
    pull subject to anonymous rate limits.

    This script mirrors the same images from a public AWS ECR repository
    (see scripts/tb2_images_to_ecr.py for how the ECR side was populated),
    where the canonical name is:
        public.ecr.aws/<alias>/<repo>:<sanitized-task-name>

    For each task in the TB2 repo:
        1. Clone (or update) the TB2 task repo to read task.toml
        2. Pull   `{TB_PUBLIC_ECR}:{tag_prefix}{task_name}`
        3. Re-tag locally as the docker_image value from task.toml so
           Harbor (which only knows the original name) finds it locally
           on the next run.

Pulls in parallel with a small worker pool. Manifest written to
`${RESULTS_DIR}/${RUN_TAG}/image_pull_manifest.json` and is resume-friendly.
"""

from __future__ import annotations

import concurrent.futures as cf
import json
import os
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

try:
    import tomllib  # py3.11+
except ModuleNotFoundError:  # pragma: no cover
    tomllib = None

# ---------------------------------------------------------------------------
# Colour / logging
# ---------------------------------------------------------------------------
GRN, YEL, RED, CYN, NC = "\033[0;32m", "\033[0;33m", "\033[0;31m", "\033[0;36m", "\033[0m"
_print_lock = threading.Lock()
def _emit(c, p, m):
    with _print_lock:
        print(f"{c}[tb-pull] {p}{m}{NC}", flush=True)
def log(m):  _emit(CYN, "", m)
def ok(m):   _emit(GRN, "✓ ", m)
def warn(m): _emit(YEL, "⚠ ", m)
def err(m):  _emit(RED, "✗ ", m)

# ---------------------------------------------------------------------------
# Config from environment
# ---------------------------------------------------------------------------
RESULTS_DIR  = Path(os.environ.get("RESULTS_DIR", str(Path.home() / "baseline-results")))
RUN_TAG      = os.environ.get("RUN_TAG", "latest")
TB_PUBLIC_ECR = os.environ.get("TB_PUBLIC_ECR",
                               "public.ecr.aws/l7z4o9j8/holboxai/terminal-bench-2")
TAG_PREFIX   = os.environ.get("TB_TAG_PREFIX", "")
TB2_REPO_URL = os.environ.get("TB2_REPO_URL",
                              "https://github.com/laude-institute/terminal-bench-2.git")
TB2_REF      = os.environ.get("TB2_REF", "main")
TB2_WORK_DIR = Path(os.environ.get("TB2_WORK_DIR",
                                   str(Path.home() / "terminal-bench-2-src")))
TASK_FILTER  = os.environ.get("TASK_FILTER", "")
MAX_WORKERS  = int(os.environ.get("PULL_WORKERS", "4"))
PLATFORM     = os.environ.get("PLATFORM", "linux/amd64")
MANIFEST_PATH = RESULTS_DIR / RUN_TAG / "image_pull_manifest.json"


# ---------------------------------------------------------------------------
# Shell helpers
# ---------------------------------------------------------------------------
def run(cmd, timeout=None, _input=None):
    r = subprocess.run(cmd, capture_output=True, text=True,
                       timeout=timeout, input=_input)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def docker_image_exists(image: str) -> bool:
    rc, _ = run(["docker", "image", "inspect", image], timeout=10)
    return rc == 0


def is_rate_limited(s: str) -> bool:
    s = s.lower()
    return any(k in s for k in ("toomanyrequests", "429", "rate limit", "too many requests"))


def docker_pull(image: str, platform: str = PLATFORM, timeout: int = 1800):
    delay = 30
    for attempt in range(1, 9):
        rc, out = run(["docker", "pull", "--platform", platform, image], timeout=timeout)
        if rc == 0:
            return True, out
        if is_rate_limited(out):
            warn(f"rate-limited pulling {image} (attempt {attempt}/8) — sleeping {delay}s")
            time.sleep(delay); delay = min(delay * 2, 1800)
            continue
        return False, out
    return False, "rate-limited after 8 attempts"


# ---------------------------------------------------------------------------
# Public ECR login (optional — public ECR allows anonymous pulls but the rate
# limit is higher when authenticated as AWS).
# ---------------------------------------------------------------------------
def public_ecr_login():
    if not TB_PUBLIC_ECR.startswith("public.ecr.aws/"):
        return
    rc, pw = run(["aws", "ecr-public", "get-login-password", "--region", "us-east-1"])
    if rc != 0:
        warn("`aws ecr-public get-login-password` failed — falling back to anonymous pulls")
        warn(pw.strip()[:200])
        return
    rc, out = run(["docker", "login", "--username", "AWS",
                   "--password-stdin", "public.ecr.aws"], _input=pw.strip())
    if rc != 0:
        warn(f"docker login public.ecr.aws failed: {out.strip()[:200]}")
        return
    ok("Logged in to public.ecr.aws (raised pull rate limit)")


# ---------------------------------------------------------------------------
# Clone / update the TB2 task repo so we can read task.toml for each task.
# ---------------------------------------------------------------------------
def clone_repo(url: str, ref: str, dest: Path) -> Path:
    if (dest / ".git").is_dir():
        log(f"Updating existing TB2 checkout at {dest} (ref={ref})…")
        run(["git", "-C", str(dest), "fetch", "--depth", "1", "origin", ref])
        rc, _ = run(["git", "-C", str(dest), "checkout", "-f", "FETCH_HEAD"])
        if rc != 0:
            run(["git", "-C", str(dest), "checkout", "-f", ref])
    else:
        log(f"Cloning {url} (ref={ref}, shallow) → {dest}…")
        rc, _ = run(["git", "clone", "--depth", "1", "--branch", ref, url, str(dest)])
        if rc != 0:
            run(["git", "clone", url, str(dest)])
            run(["git", "-C", str(dest), "checkout", "-f", ref])
    if not dest.is_dir():
        sys.exit(f"TB2 repo not present at {dest} after clone.")
    return dest


def parse_docker_image(toml_path: Path) -> str | None:
    text = toml_path.read_text(errors="ignore")
    if tomllib:
        try:
            data = tomllib.loads(text)
            v = data.get("docker_image")
            if isinstance(v, str) and v.strip():
                return v.strip()
        except Exception:
            pass
    m = re.search(r'^\s*docker_image\s*=\s*"([^"]+)"', text, re.M)
    return m.group(1).strip() if m else None


def discover_tasks(repo_dir: Path, task_filter: str) -> list[dict]:
    pat = re.compile(task_filter) if task_filter else None
    tasks = []
    for toml in sorted(Path(repo_dir).glob("*/task.toml")):
        name = toml.parent.name
        if pat and not pat.search(name):
            continue
        tasks.append({
            "task": name,
            "dir": toml.parent,
            "docker_image": parse_docker_image(toml),
        })
    return tasks


# ---------------------------------------------------------------------------
# ECR tag naming (mirrors tb2_images_to_ecr.py:ecr_tags_for)
# ---------------------------------------------------------------------------
def sanitize_tag(t: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "-", t)[:128]


def ecr_ref_for(task_name: str) -> str:
    return f"{TB_PUBLIC_ECR}:{sanitize_tag(TAG_PREFIX + task_name)}"


# ---------------------------------------------------------------------------
# Per-task pull
# ---------------------------------------------------------------------------
def pull_one(t: dict) -> dict:
    task = t["task"]
    target_name = t["docker_image"]  # the name Harbor will look up at run time

    if not target_name:
        return {"task": task, "status": "no_image"}

    # Local image already present under the target name? Skip.
    if docker_image_exists(target_name):
        return {"task": task, "status": "skipped", "image": target_name}

    ecr_ref = ecr_ref_for(task)
    pulled, out = docker_pull(ecr_ref)
    if not pulled:
        err(f"[fail] {task} — pull '{ecr_ref}' failed: {out.strip()[:200]}")
        return {"task": task, "status": "failed",
                "ecr_ref": ecr_ref, "error": out.strip()[:300]}

    # Re-tag to the original name so Harbor finds it locally.
    rc, tag_out = run(["docker", "tag", ecr_ref, target_name])
    if rc != 0:
        err(f"[fail] {task} — retag '{ecr_ref}' → '{target_name}' failed: {tag_out.strip()[:200]}")
        return {"task": task, "status": "retag_failed",
                "ecr_ref": ecr_ref, "image": target_name,
                "error": tag_out.strip()[:300]}

    return {"task": task, "status": "pulled",
            "ecr_ref": ecr_ref, "image": target_name}


# ---------------------------------------------------------------------------
# Manifest helpers
# ---------------------------------------------------------------------------
def load_manifest() -> dict:
    if MANIFEST_PATH.exists():
        try:
            return json.loads(MANIFEST_PATH.read_text())
        except Exception:
            pass
    return {"pulled": [], "skipped": [], "failed": [], "no_image": []}


def save_manifest(m: dict) -> None:
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST_PATH.write_text(json.dumps(m, indent=2))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    manifest = load_manifest()
    already_done = set(manifest.get("pulled", []) + manifest.get("skipped", []))

    public_ecr_login()

    repo_dir = clone_repo(TB2_REPO_URL, TB2_REF, TB2_WORK_DIR)
    tasks = discover_tasks(repo_dir, TASK_FILTER)
    with_image = [t for t in tasks if t["docker_image"]]
    log(f"Discovered {len(tasks)} task(s); {len(with_image)} declare a docker_image"
        + (f"; filter='{TASK_FILTER}'" if TASK_FILTER else ""))
    if not tasks:
        warn("No tasks found in TB2 repo — nothing to pull")
        return 0

    todo = [t for t in with_image if t["task"] not in already_done]
    log(f"Already done: {len(already_done)} | Remaining: {len(todo)}")
    log(f"Source: {TB_PUBLIC_ECR}")
    if not todo:
        ok("All images already pulled — nothing to do")
        return 0

    pulled    = list(manifest.get("pulled", []))
    skipped   = list(manifest.get("skipped", []))
    failed    = list(manifest.get("failed", []))
    no_image  = list(manifest.get("no_image", []))

    log(f"Pulling {len(todo)} images with {MAX_WORKERS} worker(s)…")
    with cf.ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futs = {pool.submit(pull_one, t): t["task"] for t in todo}
        done = 0
        for fut in cf.as_completed(futs):
            result = fut.result()
            iid = result["task"]
            status = result["status"]
            done += 1

            if status == "pulled":
                pulled.append(iid)
                ok(f"[{done}/{len(todo)}] {iid} ← {result.get('ecr_ref','?')}")
            elif status == "skipped":
                skipped.append(iid)
                log(f"[{done}/{len(todo)}] {iid} already present locally")
            elif status == "no_image":
                no_image.append(iid)
                log(f"[{done}/{len(todo)}] {iid} declares no docker_image")
            else:
                failed.append(iid)

            if done % 10 == 0:
                save_manifest({"pulled": pulled, "skipped": skipped,
                               "failed": failed, "no_image": no_image})

    save_manifest({"pulled": pulled, "skipped": skipped,
                   "failed": failed, "no_image": no_image})

    print()
    ok(f"Done — pulled: {len(pulled)}, skipped: {len(skipped)}, "
       f"failed: {len(failed)}, no_image: {len(no_image)}")
    if failed:
        warn(f"Failed ({len(failed)}): {failed[:5]}{'…' if len(failed) > 5 else ''}")
        warn("Failed images will fall back to Harbor's default Docker Hub pull at run time.")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
