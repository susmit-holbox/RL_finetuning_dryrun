#!/usr/bin/env python3
"""
tb2_images_to_ecr.py — Mirror Terminal-Bench 2.0 task images into AWS ECR.

Terminal-Bench 2.0 (the `terminal-bench@2.0` dataset, NOT terminal-bench-core)
runs under the **Harbor** harness. Each task ships a `task.toml` that names a
PRE-BUILT image, e.g.:

    docker_image = "alexgshaw/adaptive-rejection-sampler:20251031"

Harbor pulls that image at run time (the task's environment/Dockerfile is just
the source used to publish it). So the images are already pullable from a public
registry (typically Docker Hub) — this script mirrors them into your ECR:

    1. shallow-clone the TB2 task repo to read every task's `docker_image`
    2. `docker pull` each image  (Docker Hub login + rate-limit backoff)
    3. retag into your ECR repository (one tag per task; + a version tag)
    4. `docker push`  (auto ECR login + repo creation)
    5. remove the local copy after push (default) to conserve disk

Resumable: tasks whose ECR tag already exists are skipped (unless --force).

------------------------------------------------------------------------------
Quick start
------------------------------------------------------------------------------
    export ECR_REGISTRY="123456789012.dkr.ecr.us-east-1.amazonaws.com/mach11/terminal-bench-2"
    export DOCKER_USERNAME=... DOCKER_PASSWORD=...     # optional, raises pull quota
    python3 tb2_images_to_ecr.py                        # mirror everything
    python3 tb2_images_to_ecr.py --task-filter 'chess|pytorch'   # subset
    python3 tb2_images_to_ecr.py --workers 6 --no-prune          # keep local images

All options can be given as flags or the matching UPPER_CASE env var.
"""
import argparse
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
def _log(c, p, m):
    with _print_lock:
        print(f"{c}[tb2-ecr] {p}{m}{NC}", flush=True)
def log(m):  _log(CYN, "", m)
def ok(m):   _log(GRN, "✓ ", m)
def warn(m): _log(YEL, "⚠ ", m)
def err(m):  _log(RED, "✗ ", m)
def die(m):  err(m); sys.exit(1)


# ---------------------------------------------------------------------------
# Config (flags override env override defaults)
# ---------------------------------------------------------------------------
def parse_args():
    def env(k, d=None): return os.environ.get(k, d)
    ap = argparse.ArgumentParser(description="Mirror Terminal-Bench 2.0 images into ECR")
    ap.add_argument("--ecr-registry", default=env("ECR_REGISTRY"),
                    help="ECR repo URI: <acct>.dkr.ecr.<region>.amazonaws.com/<namespace>/<repo>")
    ap.add_argument("--aws-region", default=env("AWS_REGION"),
                    help="AWS region (default: parsed from the ECR URI)")
    ap.add_argument("--repo-url", default=env("TB2_REPO_URL",
                    "https://github.com/laude-institute/terminal-bench-2.git"))
    ap.add_argument("--ref", default=env("TB2_REF", "main"),
                    help="git ref (branch/tag/commit) of the TB2 task repo")
    ap.add_argument("--work-dir", default=env("WORK_DIR",
                    str(Path.home() / "terminal-bench-2-src")))
    ap.add_argument("--tag-prefix", default=env("TAG_PREFIX", ""),
                    help="prepended to every ECR tag (e.g. 'tb2.')")
    ap.add_argument("--no-version-tag", action="store_true",
                    default=env("KEEP_VERSION_TAG", "1") == "0",
                    help="don't also push <task>.<orig-tag> for provenance")
    ap.add_argument("--workers", type=int, default=int(env("WORKERS", "4")))
    ap.add_argument("--no-prune", action="store_true",
                    default=env("PRUNE_AFTER_PUSH", "1") == "0",
                    help="keep local images after push (default: remove to save disk)")
    ap.add_argument("--task-filter", default=env("TASK_FILTER", ""),
                    help="only mirror tasks whose name matches this regex")
    ap.add_argument("--force", action="store_true", default=env("FORCE", "0") == "1",
                    help="re-pull/push even if the ECR tag already exists")
    ap.add_argument("--hydrate", action="store_true", default=env("HYDRATE", "0") == "1",
                    help="REVERSE mode: pull each task image FROM your ECR and retag it to "
                         "the name task.toml expects (alexgshaw/<task>:<tag>) so Harbor runs "
                         "it locally and never pulls Docker Hub. No pushing.")
    ap.add_argument("--build-fallback", action="store_true",
                    default=env("BUILD_FALLBACK", "0") == "1",
                    help="if a task has no docker_image, build it from environment/Dockerfile")
    ap.add_argument("--platform", default=env("PLATFORM", "linux/amd64"))
    ap.add_argument("--manifest", default=env("MANIFEST_PATH",
                    str(Path.cwd() / "tb2_ecr_manifest.json")))
    args = ap.parse_args()
    if not args.ecr_registry:
        die("ECR_REGISTRY is required (flag --ecr-registry or env ECR_REGISTRY).")
    return args


# ---------------------------------------------------------------------------
# Shell helpers
# ---------------------------------------------------------------------------
def run(cmd, timeout=None, capture=True, _input=None):
    """Run a command; return (rc, combined_output)."""
    r = subprocess.run(cmd, capture_output=capture, text=True, timeout=timeout, input=_input)
    out = (r.stdout or "") + (r.stderr or "") if capture else ""
    return r.returncode, out

def have(binary):
    return run(["bash", "-lc", f"command -v {binary}"])[0] == 0

def image_exists(ref):
    return run(["docker", "image", "inspect", ref])[0] == 0

def is_rate_limited(s):
    s = s.lower()
    return any(k in s for k in ("toomanyrequests", "429", "rate limit", "too many requests"))


# ---------------------------------------------------------------------------
# ECR / registry helpers
# ---------------------------------------------------------------------------
def parse_ecr(uri, region_override=None):
    """Return an ECR context dict, auto-detecting PRIVATE vs PUBLIC ECR.

    PRIVATE: <acct>.dkr.ecr.<region>.amazonaws.com/<repo...>
             -> aws ecr ...,  login host = the full <acct>.dkr.ecr... host
    PUBLIC : public.ecr.aws/<alias>/<repo...>
             -> aws ecr-public ...,  login host = public.ecr.aws,  region us-east-1
             (ECR Public auth/control-plane is ALWAYS us-east-1)
    """
    if "/" not in uri:
        die(f"ECR_REGISTRY must include a repository path, got: {uri}")
    host = uri.split("/", 1)[0]
    if host == "public.ecr.aws":
        parts = uri.split("/")
        if len(parts) < 3:
            die("Public ECR URI must look like public.ecr.aws/<alias>/<repo>, got: " + uri)
        return {"public": True, "svc": "ecr-public", "login_host": "public.ecr.aws",
                "alias": parts[1], "repo": "/".join(parts[2:]), "region": "us-east-1"}
    repo = uri.split("/", 1)[1]
    m = re.match(r"[0-9]+\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com$", host)
    region = region_override or (m.group(1) if m else None)
    return {"public": False, "svc": "ecr", "login_host": host,
            "alias": None, "repo": repo, "region": region}

def ecr_login(ec):
    rc, pw = run(["aws", ec["svc"], "get-login-password", "--region", ec["region"]])
    if rc != 0:
        die(f"`aws {ec['svc']} get-login-password` failed (check AWS creds / region):\n{pw}")
    rc, out = run(["docker", "login", "--username", "AWS", "--password-stdin", ec["login_host"]],
                  _input=pw.strip())
    if rc != 0:
        die(f"docker login to {ec['login_host']} failed:\n{out}")
    ok(f"Logged in to {'PUBLIC ' if ec['public'] else ''}ECR: {ec['login_host']}"
       + (f" (alias {ec['alias']})" if ec['public'] else ""))

def ecr_ensure_repo(ec):
    rc, _ = run(["aws", ec["svc"], "describe-repositories",
                 "--repository-names", ec["repo"], "--region", ec["region"]])
    if rc == 0:
        return
    log(f"Creating {'public ' if ec['public'] else ''}ECR repository '{ec['repo']}'…")
    cmd = ["aws", ec["svc"], "create-repository", "--repository-name", ec["repo"],
           "--region", ec["region"]]
    if not ec["public"]:
        cmd += ["--image-tag-mutability", "MUTABLE"]
    rc, out = run(cmd)
    if rc != 0 and "RepositoryAlreadyExistsException" not in out:
        die(f"Could not create ECR repo '{ec['repo']}':\n{out}")
    ok(f"ECR repository ready: {ec['repo']}")

def ecr_tag_exists(ec, tag):
    # ECR Public has no describe-images; fall back to a registry HEAD via manifest.
    if ec["public"]:
        rc, _ = run(["docker", "manifest", "inspect",
                     f"{ec['login_host']}/{ec['alias']}/{ec['repo']}:{tag}"])
        return rc == 0
    rc, _ = run(["aws", "ecr", "describe-images", "--repository-name", ec["repo"],
                 "--region", ec["region"], "--image-ids", f"imageTag={tag}"])
    return rc == 0

def dockerhub_login(user, pw):
    if not user or not pw:
        return
    rc, out = run(["docker", "login", "--username", user, "--password-stdin"], _input=pw)
    ok("Docker Hub login OK") if rc == 0 else warn(f"Docker Hub login failed: {out.strip()[:200]}")


# ---------------------------------------------------------------------------
# Task discovery
# ---------------------------------------------------------------------------
def clone_repo(url, ref, dest):
    dest = Path(dest)
    if (dest / ".git").is_dir():
        log(f"Updating existing TB2 checkout at {dest} (ref={ref})…")
        run(["git", "-C", str(dest), "fetch", "--depth", "1", "origin", ref])
        rc, out = run(["git", "-C", str(dest), "checkout", "-f", "FETCH_HEAD"])
        if rc != 0:
            run(["git", "-C", str(dest), "checkout", "-f", ref])
    else:
        log(f"Cloning {url} (ref={ref}, shallow) → {dest}…")
        rc, out = run(["git", "clone", "--depth", "1", "--branch", ref, url, str(dest)])
        if rc != 0:  # ref may be a commit, not a branch/tag → full-ish fallback
            run(["git", "clone", url, str(dest)])
            run(["git", "-C", str(dest), "checkout", "-f", ref])
    if not dest.is_dir():
        die(f"TB2 repo not present at {dest} after clone.")
    return dest

def parse_docker_image(toml_path):
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

def discover_tasks(repo_dir, task_filter):
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
# Per-task mirror
# ---------------------------------------------------------------------------
def docker_pull(image, platform, timeout=1800):
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

def ecr_tags_for(task, orig_tag, prefix, version_tag):
    tags = [f"{prefix}{task}"]
    if version_tag and orig_tag:
        tags.append(f"{prefix}{task}.{orig_tag}")
    # ECR tags: <=128 chars, [A-Za-z0-9._-] only
    return [re.sub(r"[^A-Za-z0-9._-]", "-", t)[:128] for t in tags]

def hydrate_one(t, cfg, ec):
    """Pull a task image FROM ECR and retag it to the name task.toml declares,
    so Harbor finds it locally (compose pull_policy=missing) and skips Docker Hub."""
    task, src = t["task"], t["docker_image"]
    if not src:
        return {"task": task, "status": "no_image"}
    if not cfg.force and image_exists(src):
        log(f"[skip] {task} — '{src}' already present locally")
        return {"task": task, "status": "skipped", "src": src}
    primary_tag = ecr_tags_for(task, None, cfg.tag_prefix, False)[0]
    ecr_ref = f"{cfg.ecr_registry}:{primary_tag}"
    ok_pull, out = docker_pull(ecr_ref, cfg.platform)
    if not ok_pull:
        err(f"[fail] {task} — pull '{ecr_ref}' failed: {out.strip()[:200]}")
        return {"task": task, "status": "pull_failed", "ecr": ecr_ref, "error": out.strip()[:300]}
    run(["docker", "tag", ecr_ref, src])
    if not cfg.no_prune and ecr_ref != src:
        run(["docker", "rmi", ecr_ref])  # keep only the alexgshaw/... tag Harbor needs
    ok(f"[done] {task} — {ecr_ref} → {src}")
    return {"task": task, "status": "hydrated", "src": src, "ecr": ecr_ref}


def mirror_one(t, cfg, ec):
    task = t["task"]
    src = t["docker_image"]
    orig_tag = src.rsplit(":", 1)[1] if (src and ":" in src.rsplit("/", 1)[-1]) else "latest"
    tags = ecr_tags_for(task, orig_tag if src else None, cfg.tag_prefix, not cfg.no_version_tag)
    ecr_refs = [f"{cfg.ecr_registry}:{tg}" for tg in tags]
    primary_tag = tags[0]

    # Resume: primary tag already in ECR?
    if not cfg.force and ecr_tag_exists(ec, primary_tag):
        log(f"[skip] {task} — ECR tag '{primary_tag}' already present")
        return {"task": task, "status": "skipped", "src": src, "ecr": ecr_refs}

    # Materialise the image locally (pull, or build fallback).
    if src:
        ok_pull, out = docker_pull(src, cfg.platform)
        if not ok_pull:
            err(f"[fail] {task} — pull '{src}' failed: {out.strip()[:200]}")
            return {"task": task, "status": "pull_failed", "src": src, "error": out.strip()[:300]}
        local = src
    elif cfg.build_fallback and (t["dir"] / "environment" / "Dockerfile").is_file():
        local = f"tb2-build/{task}:latest"
        warn(f"[build] {task} — no docker_image; building environment/Dockerfile")
        rc, out = run(["docker", "build", "--platform", cfg.platform, "-t", local,
                       str(t["dir"] / "environment")], timeout=t.get("build_timeout", 1800), capture=True)
        if rc != 0:
            err(f"[fail] {task} — build failed: {out.strip()[-300:]}")
            return {"task": task, "status": "build_failed", "src": None, "error": out.strip()[-300:]}
    else:
        warn(f"[skip] {task} — no docker_image and build fallback off")
        return {"task": task, "status": "no_image", "src": None}

    # Tag + push each ECR ref.
    for ref in ecr_refs:
        run(["docker", "tag", local, ref])
        rc, out = run(["docker", "push", ref], timeout=1800)
        if rc != 0:
            err(f"[fail] {task} — push '{ref}' failed: {out.strip()[:200]}")
            return {"task": task, "status": "push_failed", "src": src, "ecr": ecr_refs,
                    "error": out.strip()[:300]}

    # Conserve disk: drop the local copies we created (the underlying layers are
    # already in ECR). `local` is the pulled src image or the built tag.
    if not cfg.no_prune:
        for ref in ecr_refs:
            run(["docker", "rmi", ref])
        run(["docker", "rmi", local])

    ok(f"[done] {task} → {', '.join(tags)}")
    return {"task": task, "status": "pushed", "src": src, "ecr": ecr_refs}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    cfg = parse_args()

    for b in ("docker", "aws", "git"):
        if not have(b):
            die(f"required tool '{b}' not found on PATH.")
    if run(["docker", "info"])[0] != 0:
        die("Docker daemon is not running.")

    ec = parse_ecr(cfg.ecr_registry, cfg.aws_region)
    if not ec["region"]:
        die("Could not determine AWS region — pass --aws-region or use a standard ECR URI.")
    kind = "PUBLIC" if ec["public"] else "private"
    log(f"{kind} ECR | svc=aws {ec['svc']} | login_host={ec['login_host']} "
        f"| repo={ec['repo']} | region={ec['region']}")

    if cfg.hydrate:
        # Reverse mode: pull from ECR, retag to task.toml names. Read-only on ECR.
        if not ec["public"]:
            ecr_login(ec)  # private pull needs auth; public ECR pull is anonymous
        worker, verb = hydrate_one, "Hydrating"
    else:
        ecr_login(ec)
        ecr_ensure_repo(ec)
        dockerhub_login(os.environ.get("DOCKER_USERNAME", ""), os.environ.get("DOCKER_PASSWORD", ""))
        worker, verb = mirror_one, "Mirroring"

    repo_dir = clone_repo(cfg.repo_url, cfg.ref, cfg.work_dir)
    tasks = discover_tasks(repo_dir, cfg.task_filter)
    with_img = [t for t in tasks if t["docker_image"]]
    log(f"Discovered {len(tasks)} task(s); {len(with_img)} declare a docker_image"
        + (f"; filter='{cfg.task_filter}'" if cfg.task_filter else ""))
    if not tasks:
        die("No tasks found — check --ref / --task-filter / repo layout.")

    results = []
    log(f"{verb} with {cfg.workers} worker(s)…")
    with cf.ThreadPoolExecutor(max_workers=cfg.workers) as pool:
        futs = {pool.submit(worker, t, cfg, ec): t["task"] for t in tasks}
        done = 0
        for fut in cf.as_completed(futs):
            done += 1
            try:
                results.append(fut.result())
            except Exception as e:  # never let one task kill the run
                results.append({"task": futs[fut], "status": "error", "error": repr(e)})
            if done % 10 == 0:
                Path(cfg.manifest).write_text(json.dumps(results, indent=2))

    Path(cfg.manifest).write_text(json.dumps(results, indent=2))
    by = {}
    for r in results:
        by.setdefault(r["status"], []).append(r["task"])
    print()
    log("=" * 60)
    for status, names in sorted(by.items()):
        line = f"{status:14} {len(names)}"
        if status not in ("pushed", "skipped"):
            line += f"  -> {names[:8]}{'…' if len(names) > 8 else ''}"
        log(line)
    ok(f"Manifest: {cfg.manifest}")
    bad = sum(len(v) for k, v in by.items()
              if k not in ("pushed", "hydrated", "skipped", "no_image"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
