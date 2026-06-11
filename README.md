# qwen-baseline-eval (cloud / DashScope)

End-to-end **TerminalBench** evaluation of a Qwen model served by **Alibaba
Cloud DashScope** (OpenAI-compatible endpoint), with task images pre-pulled
from a **public AWS ECR mirror** instead of Docker Hub.

| Benchmark | Agent | LLM | Images |
|---|---|---|---|
| **TerminalBench** | [`Terminus`](https://github.com/laude-institute/terminal-bench) (terminus-2 + XML parser by default) | DashScope `qwen3.7-max` (OpenAI-compatible) | `public.ecr.aws/l7z4o9j8/holboxai/terminal-bench-2` |

> **Why DashScope:** no GPUs to provision, no vLLM to install, no model
> weights to download — inference happens in Alibaba Cloud and Terminus
> talks to it over the OpenAI Chat Completions API.
>
> **Why a public ECR mirror:** TerminalBench-2 task images live on Docker
> Hub by default (e.g. `alexgshaw/adaptive-rejection-sampler:20251031`),
> which has aggressive anonymous rate limits. Mirroring them into public
> ECR (see `scripts/tb2_images_to_ecr.py`) avoids the limit entirely.

> **Why Terminus:** terminal-bench's reference agent. Runs in the **host**
> `tb` process and drives each task container over tmux, parsing a JSON/XML
> command batch from text — it does **not** use OpenAI `tool_calls`, so
> tool-call parser quirks on the model side can't break it.

---

## Quick start

```bash
# 1. Edit configuration
nano config.env        # at minimum set DASHSCOPE_API_KEY and DASHSCOPE_WORKSPACE_ID

# 2. Start a screen session
screen -S baseline_eval

# 3. Run everything
bash run.sh 2>&1 | tee ~/baseline_run.log

# Detach:  Ctrl+A, D
# Reattach: screen -r baseline_eval
```

Results land in `${RESULTS_DIR}/${RUN_TAG}/` and a tarball is created automatically.

---

## Configuration (`config.env`)

| Variable | Default | Description |
|---|---|---|
| `MODEL_NAME` | `qwen3.7-max` | DashScope model id (the value passed to `client.chat.completions.create(model=…)`) |
| `MODEL_ID`   | _(falls back to `MODEL_NAME`)_ | Provenance label written into result summaries |
| `DASHSCOPE_API_KEY` | _(required)_ | Your DashScope API key |
| `DASHSCOPE_REGION`  | `ap-southeast-1` | One of `ap-southeast-1` / `us` / `cn-beijing` / `cn-hongkong` / `eu-central-1` |
| `DASHSCOPE_WORKSPACE_ID` | _(required for Singapore/HK/Frankfurt)_ | Workspace id used to build the regional base URL |
| `DASHSCOPE_BASE_URL` | _(derived)_ | Overrides the resolved base URL if you set it explicitly |
| `MAX_MODEL_LEN` | `131072` | Context-window size advertised to litellm (so Terminus-2 trims correctly) |
| `TB_PUBLIC_ECR` | `public.ecr.aws/l7z4o9j8/holboxai/terminal-bench-2` | Public ECR repo with the mirrored TB-2 images |
| `TB_TAG_PREFIX` | _(blank)_ | Optional prefix matching the value used when mirroring (e.g. `tb2.`) |
| `TB2_REPO_URL` | `https://github.com/laude-institute/terminal-bench-2.git` | Git source for `task.toml`s |
| `TB2_REF` | `main` | Branch / tag / commit |
| `TB2_WORK_DIR` | `~/terminal-bench-2-src` | Where to clone it locally |
| `TASK_FILTER` | _(blank)_ | Regex restricting which tasks to pull/run |
| `TB_VENV_DIR` | `~/tb_venv` | Isolated uv venv for terminal-bench |
| `TB_VERSION` | `0.2.18` | Pinned terminal-bench version |
| `TB_AGENT`   | `terminus-2` | `terminus` (=terminus-1) or `terminus-2` (more robust) |
| `TB_PARSER`  | `xml` | terminus-2 only: `xml` (forgiving) or `json` |
| `TERMINALBENCH_DATASET` | `terminal-bench` | dataset name |
| `TERMINALBENCH_VERSION` | `2.0` | dataset version |
| `TERMINALBENCH_WORKERS` | `4` | concurrent task containers |
| `RESULTS_DIR` | `~/baseline-results` | where step outputs land |
| `S3_RESULTS_URI` | _(blank)_ | e.g. `s3://my-bucket/baseline` — sync results here |
| `PULL_WORKERS` | `4` | parallel image pulls in step 8 |

### Region → base URL mapping

| Region | Base URL |
|---|---|
| `ap-southeast-1` (Singapore) | `https://{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1` |
| `us` (Virginia) | `https://dashscope-us.aliyuncs.com/compatible-mode/v1` |
| `cn-beijing` | `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| `cn-hongkong` | `https://{WorkspaceId}.cn-hongkong.maas.aliyuncs.com/compatible-mode/v1` |
| `eu-central-1` (Frankfurt) | `https://{WorkspaceId}.eu-central-1.maas.aliyuncs.com/compatible-mode/v1` |

---

## Steps

| # | Script | What it does |
|---|---|---|
| 1 | `01_setup_env.sh` | Install Docker + AWS CLI + uv-managed Python 3.12; create eval venv |
| 5 | `05_test_endpoint.py` | Probe the DashScope endpoint with a basic chat and a tool-call test (tool-call result is informational only) |
| 6 | `06_setup_agents.sh` | Create the terminal-bench uv venv and install Terminus |
| 8 | `08_pull_tb_images.py` | Clone the TB-2 task repo; pull each task's image from public ECR and locally re-tag it as the `docker_image` Harbor expects |
| 9 | `09_run_terminalbench.sh` | `tb run --agent terminus-2 --model openai/<name>` → DashScope endpoint |
| 11 | `11_collect_results.sh` | Archive results, optionally sync to S3 |

---

## How the image pull works

`scripts/tb2_images_to_ecr.py` is the upstream mirror script: it walks the
TB-2 task repo, reads each `task.toml`, and pushes the original Docker Hub
image to public ECR under the tag `<task-name>` (sanitized — non-alphanum →
`-`, capped at 128 chars).

`scripts/08_pull_tb_images.py` is the reverse direction: it walks the same
`task.toml`s, derives the ECR tag with the same naming rule, `docker pull`s
from public ECR, then `docker tag`s the result back to the original
`docker_image` name so the Harbor harness finds it locally without ever
touching Docker Hub.

If you used a `TAG_PREFIX` when mirroring (e.g. `tb2.`), set the matching
`TB_TAG_PREFIX` here.

---

## Results layout

```
${RESULTS_DIR}/${RUN_TAG}/
├── SUMMARY.json                    ← top-level summary
├── endpoint_test.json              ← DashScope endpoint probe
├── image_pull_manifest.json        ← which TB-2 images were pulled / failed
└── terminalbench/
    ├── tb_run.log
    ├── <run-id>/results.json       ← tb BenchmarkResults (n_resolved, accuracy)
    └── run_summary.json
```

---

## Running individual steps

```bash
source config.env
bash scripts/09_run_terminalbench.sh
```
