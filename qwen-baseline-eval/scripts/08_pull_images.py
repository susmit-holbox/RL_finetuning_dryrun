#!/usr/bin/env python3
"""
08_pull_images.py — Pre-pull all SWE-bench Docker images.

Confirmed naming conventions (verified by actual docker pull):
  Instance ID format  : astropy__astropy-14365       (double underscore)
  ghcr.io name        : ghcr.io/epoch-research/swe-bench.eval.x86_64.astropy__astropy-14365
  Docker Hub name     : swebench/sweb.eval.x86_64.astropy_1776_astropy-14365
                        (double __ → _1776_ conversion required!)
  mini-swe-agent runs : swebench/sweb.eval.x86_64.astropy_1776_astropy-14365:latest
                        (lowercased; __ → _1776_ — SAME as Docker Hub's name)
  swebench harness    : swebench/sweb.eval.x86_64.astropy__astropy-14365:latest
                        (the scoring harness uses the raw instance_id / __ form)

Because the two consumers disagree on the local tag, every pulled image is
tagged BOTH ways locally so neither re-pulls from Docker Hub:
  • <__ form>     — for the swebench scoring harness (run_evaluation)
  • <_1776_ form> — for mini-swe-agent's per-instance Docker environment

Pull priority (highest to lowest):
  1. ECR_REGISTRY env var — private ECR already populated (no rate limits)
  2. ghcr.io/epoch-research — public, no Docker Hub rate limit, uses __ format
  3. Docker Hub swebench/ — authenticated 200/6h, requires __ → _1776_ conversion

Rate limits:
  - Docker Hub anonymous : 100 pulls / 6 h
  - Docker Hub auth      : 200 pulls / 6 h
  - ghcr.io public       : no documented limit
  - ECR                  : no rate limit
"""

import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

# ---------------------------------------------------------------------------
# Config from environment
# ---------------------------------------------------------------------------
DATASET       = os.environ.get("SWEBENCH_DATASET", "princeton-nlp/SWE-bench_Verified")
SPLIT         = os.environ.get("SWEBENCH_SPLIT", "test")
RESULTS_DIR   = Path(os.environ.get("RESULTS_DIR", str(Path.home() / "baseline-results")))
RUN_TAG       = os.environ.get("RUN_TAG", "latest")
DOCKER_USER   = os.environ.get("DOCKER_USERNAME", "")
DOCKER_PASS   = os.environ.get("DOCKER_PASSWORD", "")
LOCAL_PORT    = os.environ.get("LOCAL_REGISTRY_PORT", "5001")
MAX_WORKERS   = int(os.environ.get("PULL_WORKERS", "3"))
MANIFEST_PATH = RESULTS_DIR / RUN_TAG / "image_pull_manifest.json"

# Optional: private ECR repository that already has images
# Format: "123456789.dkr.ecr.us-east-1.amazonaws.com/my-repo"
# Images are expected as tags: sweb.eval.x86_64.<instance_id>  (__ format)
ECR_REGISTRY  = os.environ.get("ECR_REGISTRY", "")

# Colour
GRN="\033[0;32m"; YEL="\033[0;33m"; RED="\033[0;31m"; CYN="\033[0;36m"; NC="\033[0m"
def log(m):  print(f"{CYN}[pull] {m}{NC}", flush=True)
def ok(m):   print(f"{GRN}[pull] ✓ {m}{NC}", flush=True)
def warn(m): print(f"{YEL}[pull] ⚠ {m}{NC}", flush=True)
def err(m):  print(f"{RED}[pull] ✗ {m}{NC}", flush=True)


# ---------------------------------------------------------------------------
# Naming helpers
# ---------------------------------------------------------------------------
def instance_to_dh_name(instance_id: str) -> str:
    """Convert instance_id double-underscore to Docker Hub _1776_ format.
    astropy__astropy-14365  →  swebench/sweb.eval.x86_64.astropy_1776_astropy-14365
    """
    dh_id = instance_id.replace("__", "_1776_")
    return f"swebench/sweb.eval.x86_64.{dh_id}:latest"


def instance_to_gh_name(instance_id: str) -> str:
    """ghcr.io uses the double-underscore instance_id format directly."""
    return f"ghcr.io/epoch-research/swe-bench.eval.x86_64.{instance_id}:latest"


def instance_to_ecr_name(instance_id: str) -> str:
    """ECR repo with image stored as a tag using _1776_ format."""
    dh_id = instance_id.replace("__", "_1776_")
    return f"{ECR_REGISTRY}:sweb.eval.x86_64.{dh_id}"


def canonical_name(instance_id: str) -> str:
    """The __ form, used by the swebench scoring harness (run_evaluation)."""
    return f"swebench/sweb.eval.x86_64.{instance_id}:latest"


def minisweagent_name(instance_id: str) -> str:
    """The exact local tag mini-swe-agent's docker environment runs.

    Mirrors minisweagent.run.benchmarks.swebench.get_swebench_docker_image_name:
        f"docker.io/swebench/sweb.eval.x86_64.{__→_1776_}:latest".lower()
    `docker.io/swebench/x` and `swebench/x` resolve to the SAME local image, so
    tagging the short form is sufficient for `docker run` to hit it locally.
    """
    dh_id = instance_id.replace("__", "_1776_")
    return f"swebench/sweb.eval.x86_64.{dh_id}:latest".lower()


# ---------------------------------------------------------------------------
# Docker helpers
# ---------------------------------------------------------------------------
def docker_image_exists(image: str) -> bool:
    r = subprocess.run(["docker", "image", "inspect", image],
                       capture_output=True, timeout=10)
    return r.returncode == 0


def docker_pull(image: str, timeout: int = 300) -> tuple:
    r = subprocess.run(["docker", "pull", image],
                       capture_output=True, text=True, timeout=timeout)
    return r.returncode == 0, r.stderr + r.stdout


def is_rate_limited(output: str) -> bool:
    return any(k in output.lower() for k in [
        "toomanyrequests", "429", "rate limit", "too many requests",
    ])


def docker_login() -> bool:
    if not DOCKER_USER or not DOCKER_PASS:
        return False
    log(f"Logging in to Docker Hub as {DOCKER_USER}…")
    r = subprocess.run(
        ["docker", "login", "--username", DOCKER_USER, "--password-stdin"],
        input=DOCKER_PASS, capture_output=True, text=True,
    )
    if r.returncode == 0:
        ok("Docker Hub login OK")
        return True
    warn(f"Docker Hub login failed: {r.stderr.strip()}")
    return False


def ecr_login() -> bool:
    """Attempt ECR login via aws ecr get-login-password."""
    if not ECR_REGISTRY:
        return False
    region = "us-east-1"
    # Extract region from ECR URL if possible
    # ECR URL: <account>.dkr.ecr.<region>.amazonaws.com/...
    # split(".")  → ["<account>", "dkr", "ecr", "<region>", "amazonaws", ...]
    parts = ECR_REGISTRY.split(".")
    if len(parts) >= 4 and parts[2] == "ecr":
        region = parts[3]
    try:
        pw = subprocess.check_output(
            ["aws", "ecr", "get-login-password", "--region", region],
            text=True, timeout=15,
        ).strip()
        r = subprocess.run(
            ["docker", "login", "--username", "AWS", "--password-stdin", ECR_REGISTRY],
            input=pw, capture_output=True, text=True,
        )
        if r.returncode == 0:
            ok(f"ECR login OK ({ECR_REGISTRY})")
            return True
        warn(f"ECR login failed: {r.stderr.strip()}")
    except Exception as e:
        warn(f"ECR login error: {e}")
    return False


# ---------------------------------------------------------------------------
# Pull one SWE-bench image — try all sources in priority order
# ---------------------------------------------------------------------------
def pull_swebench_image(instance_id: str) -> dict:
    target = canonical_name(instance_id)  # __ form for the scoring harness

    # Already present in BOTH forms the consumers need?
    if docker_image_exists(target) and docker_image_exists(minisweagent_name(instance_id)):
        return {"instance_id": instance_id, "status": "skipped", "source": "local"}
    # Image is here but only one tag — re-tag locally (no network) and finish.
    if docker_image_exists(target):
        _tag_for_consumers(target, instance_id)
        return {"instance_id": instance_id, "status": "skipped", "source": "local"}

    # --- Source 1: ECR (no rate limit, user's private cache) ---
    if ECR_REGISTRY:
        ecr_img = instance_to_ecr_name(instance_id)
        ok_flag, _ = docker_pull(ecr_img, timeout=120)
        if ok_flag:
            subprocess.run(["docker", "tag", ecr_img, target], capture_output=True)
            _push_to_local_registry(target, instance_id)
            return {"instance_id": instance_id, "status": "pulled", "source": "ecr"}

    # --- Source 2: ghcr.io (no Docker Hub rate limit, uses __ format) ---
    gh_img = instance_to_gh_name(instance_id)
    ok_flag, _ = docker_pull(gh_img, timeout=300)
    if ok_flag:
        subprocess.run(["docker", "tag", gh_img, target], capture_output=True)
        _push_to_local_registry(target, instance_id)
        return {"instance_id": instance_id, "status": "pulled", "source": "ghcr.io"}

    # --- Source 3: Docker Hub (requires __ → _1776_ name conversion) ---
    dh_img = instance_to_dh_name(instance_id)
    delay = 30
    for attempt in range(1, 9):
        ok_flag, out = docker_pull(dh_img, timeout=300)
        if ok_flag:
            # Re-tag to the canonical __ format the scoring harness expects
            subprocess.run(["docker", "tag", dh_img, target], capture_output=True)
            _push_to_local_registry(target, instance_id)
            return {"instance_id": instance_id, "status": "pulled",
                    "source": "docker-hub", "attempts": attempt}
        if is_rate_limited(out):
            warn(f"{instance_id}: rate-limited (attempt {attempt}/8) — sleeping {delay}s")
            time.sleep(delay)
            delay = min(delay * 2, 3600)
        else:
            err(f"{instance_id}: non-rate-limit failure: {out[:200]}")
            break

    return {"instance_id": instance_id, "status": "failed",
            "tried": [gh_img, dh_img]}


def _tag_for_consumers(canonical_img: str, instance_id: str) -> None:
    """Add the local tags both consumers expect, then mirror to the pull-through
    cache. `canonical_img` is the __ form (already present locally)."""
    # mini-swe-agent's per-instance docker env looks up the _1776_ form.
    mini_tag = minisweagent_name(instance_id)
    if mini_tag != canonical_img:
        subprocess.run(["docker", "tag", canonical_img, mini_tag], capture_output=True)
    # Persist in the local pull-through registry (survives across runs).
    local_tag = f"localhost:{LOCAL_PORT}/swebench/sweb.eval.x86_64.{instance_id}:latest"
    subprocess.run(["docker", "tag", canonical_img, local_tag], capture_output=True)
    subprocess.run(["docker", "push", local_tag], capture_output=True)


# Back-compat alias (older call sites / external scripts may reference this).
_push_to_local_registry = _tag_for_consumers


# ---------------------------------------------------------------------------
# Manifest (resume support)
# ---------------------------------------------------------------------------
def load_manifest() -> dict:
    if MANIFEST_PATH.exists():
        with open(MANIFEST_PATH) as f:
            return json.load(f)
    return {"pulled": [], "failed": [], "skipped": []}


def save_manifest(manifest: dict) -> None:
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(MANIFEST_PATH, "w") as f:
        json.dump(manifest, f, indent=2)


# ---------------------------------------------------------------------------
# Enumerate instance IDs from dataset
# ---------------------------------------------------------------------------
def get_instance_ids() -> list:
    log(f"Loading instance IDs from {DATASET} ({SPLIT})…")
    try:
        from datasets import load_dataset
        ds = load_dataset(DATASET, split=SPLIT, trust_remote_code=True)
        ids = [row["instance_id"] for row in ds]
        log(f"Found {len(ids)} instances")
        return ids
    except Exception as e:
        warn(f"Could not load dataset ({e})")
        return []


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    manifest = load_manifest()
    already_done = set(manifest.get("pulled", []) + manifest.get("skipped", []))

    # Log in to registries
    docker_login()
    if ECR_REGISTRY:
        ecr_login()

    all_ids = get_instance_ids()
    if not all_ids:
        warn("No instance IDs found — skipping image pre-pull")
        return 0

    todo = [iid for iid in all_ids if iid not in already_done]
    log(f"Total: {len(all_ids)} | Already done: {len(already_done)} | Remaining: {len(todo)}")
    if ECR_REGISTRY:
        log(f"Primary source: ECR ({ECR_REGISTRY})")
    log("Secondary source: ghcr.io/epoch-research (no rate limit)")
    log("Fallback source: Docker Hub swebench/ (200 pulls/6h when authenticated)")

    if not todo:
        ok("All images already pulled — nothing to do")
        return 0

    pulled  = list(manifest.get("pulled", []))
    skipped = list(manifest.get("skipped", []))
    failed  = list(manifest.get("failed", []))

    log(f"Pulling {len(todo)} images with {MAX_WORKERS} workers…")

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futures = {pool.submit(pull_swebench_image, iid): iid for iid in todo}
        done_count = 0
        for future in as_completed(futures):
            result = future.result()
            iid = result["instance_id"]
            status = result["status"]
            done_count += 1

            if status in ("pulled", "skipped"):
                if status == "pulled":
                    pulled.append(iid)
                    ok(f"[{done_count}/{len(todo)}] {iid} ← {result.get('source','?')}")
                else:
                    skipped.append(iid)
                    log(f"[{done_count}/{len(todo)}] {iid} already present")
            else:
                failed.append(iid)
                err(f"[{done_count}/{len(todo)}] {iid} FAILED — tried: {result.get('tried', [])}")

            if done_count % 10 == 0:
                save_manifest({"pulled": pulled, "skipped": skipped, "failed": failed})

    save_manifest({"pulled": pulled, "skipped": skipped, "failed": failed})

    print()
    ok(f"Done — pulled: {len(pulled)}, skipped: {len(skipped)}, failed: {len(failed)}")
    if failed:
        warn(f"Failed ({len(failed)}): {failed[:5]}{'…' if len(failed) > 5 else ''}")
        warn("Failed images will be pulled on-demand by the agent (with retry).")

    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
