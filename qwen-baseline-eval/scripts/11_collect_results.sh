#!/usr/bin/env bash
# 11_collect_results.sh — Archive all results and optionally push to S3.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 11: Collect and archive results ==="

RUN_DIR="${RESULTS_DIR}/${RUN_TAG}"
ARCHIVE_NAME="baseline-results-${MODEL_NAME//\//-}-${RUN_TAG}.tar.gz"
ARCHIVE_PATH="${RESULTS_DIR}/${ARCHIVE_NAME}"

# ---------------------------------------------------------------------------
# Create a top-level summary
# ---------------------------------------------------------------------------
PYTHON=$(eval_python)
$PYTHON - <<PYSUM
import json
from pathlib import Path

run_dir = Path("${RUN_DIR}")
summary = {
    "run_tag": "${RUN_TAG}",
    "model_id": "${MODEL_ID}",
    "model_name": "${MODEL_NAME}",
    "provider": "dashscope",
    "llm_base_url": "${DASHSCOPE_BASE_URL}",
    "terminalbench_dataset": "${TERMINALBENCH_DATASET}",
    "terminalbench_version": "${TERMINALBENCH_VERSION}",
    "subsections": {}
}

tb_summary = run_dir / "terminalbench" / "run_summary.json"
summary["subsections"]["terminalbench"] = (
    json.loads(tb_summary.read_text()) if tb_summary.exists() else "not_run"
)

endpoint_file = run_dir / "endpoint_test.json"
if endpoint_file.exists():
    ep = json.loads(endpoint_file.read_text())
    summary["endpoint_basic_ok"] = ep.get("basic_completion_ok", False)
    summary["endpoint_tool_calls_populated"] = ep.get("tool_calls_populated", False)

out = run_dir / "SUMMARY.json"
out.write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
PYSUM

# ---------------------------------------------------------------------------
# Archive
# ---------------------------------------------------------------------------
log "Creating archive ${ARCHIVE_PATH}…"
tar -czf "$ARCHIVE_PATH" \
    -C "${RESULTS_DIR}" \
    "${RUN_TAG}" \
    2>/dev/null || warn "Archive creation had warnings (non-fatal)"

ok "Archive: ${ARCHIVE_PATH} ($(du -sh "${ARCHIVE_PATH}" | cut -f1))"

# ---------------------------------------------------------------------------
# Upload to S3 (optional)
# ---------------------------------------------------------------------------
if [[ -n "${S3_RESULTS_URI:-}" ]]; then
    log "Syncing full results to ${S3_RESULTS_URI}…"
    aws s3 sync "${RUN_DIR}" "${S3_RESULTS_URI}/${RUN_TAG}/" --quiet && \
        ok "S3 sync complete: ${S3_RESULTS_URI}/${RUN_TAG}/" || \
        warn "S3 sync failed"

    log "Uploading archive to ${S3_RESULTS_URI}/archives/…"
    aws s3 cp "$ARCHIVE_PATH" "${S3_RESULTS_URI}/archives/${ARCHIVE_NAME}" --quiet && \
        ok "Archive uploaded" || \
        warn "Archive upload failed"
fi

# ---------------------------------------------------------------------------
# Print file tree
# ---------------------------------------------------------------------------
log "Results tree:"
find "${RUN_DIR}" -maxdepth 3 -type f | sort | while read -r f; do
    SIZE=$(du -sh "$f" 2>/dev/null | cut -f1)
    echo "    [${SIZE}]  ${f#${RESULTS_DIR}/}"
done

ok "=== All results collected at ${RUN_DIR} ==="
