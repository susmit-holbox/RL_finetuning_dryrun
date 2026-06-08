# qwen-baseline-eval

End-to-end baseline evaluation of a Qwen model on **SWE-bench** and **TerminalBench** via a local **vLLM** inference endpoint and **OpenHands**.

Run inside a `screen` session on a GPU instance and check back later for results.

---

## Quick start

```bash
# 1. Edit configuration
nano config.env        # at minimum set MODEL_ID, HF_HOME, RESULTS_DIR

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
| `MODEL_ID` | `Qwen/Qwen2.5-Coder-32B-Instruct` | HuggingFace model to serve |
| `MODEL_NAME` | `Qwen2.5-Coder-32B-Instruct` | Name vLLM advertises on its API |
| `MODEL_FAMILY` | `qwen2.5_coder` | Controls tool-call parser selection |
| `HF_TOKEN` | _(blank)_ | HuggingFace token for gated models |
| `HF_HOME` | `/data/models` | Weight cache directory |
| `NUM_GPUS` | `0` (auto) | GPU count for tensor parallelism |
| `VLLM_PORT` | `8000` | Port for vLLM OpenAI-compatible API |
| `MAX_MODEL_LEN` | `32768` | Context window length |
| `DOCKER_USERNAME` | _(blank)_ | Docker Hub login (increases pull quota) |
| `DOCKER_PASSWORD` | _(blank)_ | Docker Hub password |
| `SWEBENCH_LIMIT` | `500` | Number of SWE-bench instances (set to 10 for smoke test) |
| `S3_RESULTS_URI` | _(blank)_ | e.g. `s3://my-bucket/baseline` — sync results here |

### Choosing `MODEL_FAMILY`

| Value | Tool-call parser | Notes |
|---|---|---|
| `qwen2.5_coder` | `hermes` | ⚠ Silent failure: model outputs `` ```json `` blocks, `tool_calls` field empty |
| `qwen2.5` | `hermes` | Works correctly |
| `qwen3_coder` | `qwen3_coder` | Recommended for reliable tool calling |
| `qwen3` | `hermes` | Works correctly |

For reliable tool calls use `MODEL_FAMILY=qwen3_coder` with a Qwen3-Coder model.

---

## Steps

| # | Script | What it does |
|---|---|---|
| 1 | `01_setup_env.sh` | Checks CUDA, Docker, Python; installs system packages |
| 2 | `02_install_vllm.sh` | `pip install vllm` (GPU wheel) |
| 3 | `03_download_model.sh` | `huggingface-cli download` with resume support |
| 4 | `04_start_vllm.sh` | Starts `vllm serve` in a sub-screen, waits for `/health` |
| 5 | `05_test_toolcall.py` | Sends a dummy tool-call payload; surfaces parser failures |
| 6 | `06_setup_openhands.sh` | Clones OpenHands, writes `config.toml` |
| 7 | `07_setup_registry.sh` | Starts a local Docker pull-through cache (rate-limit mitigation) |
| 8 | `08_pull_images.py` | Pre-pulls all SWE-bench images with ghcr.io fallback |
| 9 | `09_run_terminalbench.sh` | `tb run --agent openhands` |
| 10 | `10_run_sweBench.sh` | `python run_infer.py --agent-cls CodeActAgent` |
| 11 | `11_collect_results.sh` | Archives results, optionally syncs to S3 |

---

## Docker rate-limit handling

SWE-bench needs ~2,290 Docker images for the Verified split.  Docker Hub
limits anonymous pulls to 100 per 6 hours.

This repo uses a **three-layer strategy**:

1. **ghcr.io/epoch-research** (primary) — GitHub Container Registry has no
   aggressive rate limits for public images.  All 500 SWE-bench Verified
   instances are mirrored here.
2. **Local pull-through cache** (`registry:2` on `localhost:LOCAL_REGISTRY_PORT`)
   — first pull goes upstream, all subsequent pulls are served locally.
   Persists across evaluation runs.
3. **Exponential backoff** — if Docker Hub returns `toomanyrequests` / HTTP 429,
   the pull script waits and retries (up to 8 attempts, capped at 1-hour delay).

Set `DOCKER_USERNAME` + `DOCKER_PASSWORD` in `config.env` to raise the Docker
Hub quota from 100 → 200 per 6 hours.

---

## Results layout

```
${RESULTS_DIR}/${RUN_TAG}/
├── SUMMARY.json                    ← top-level summary across all steps
├── toolcall_test.json              ← tool-call endpoint test result
├── image_pull_manifest.json        ← which images were pulled / failed
├── terminalbench/
│   ├── tb_run.log
│   ├── results.json
│   └── run_summary.json
└── sweBench/
    ├── swe_run.log
    ├── scoring.log
    ├── *.jsonl                     ← raw predictions
    └── run_summary.json
```

---

## Running individual steps

Each script in `scripts/` can be run independently:

```bash
source config.env
bash scripts/04_start_vllm.sh       # restart vLLM
bash scripts/09_run_terminalbench.sh # re-run TerminalBench only
```

---

## GPU requirements

| Model | Min VRAM | Recommended |
|---|---|---|
| Qwen2.5-Coder-7B | 1 × 24 GB | 1 × A10G |
| Qwen2.5-Coder-32B | 2 × 80 GB | 2 × A100 |
| Qwen3-Coder-30B-A3B (MoE) | 1 × 80 GB | 1 × A100 |
| Qwen3-Coder-480B-A35B (MoE) | 8 × 80 GB | 8 × H100 |

For Qwen3-Coder-480B add to `VLLM_EXTRA_FLAGS` in config.env:
```
VLLM_EXTRA_FLAGS="--enable-expert-parallel --max-model-len 32000"
```
