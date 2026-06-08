#!/usr/bin/env python3
"""
05_test_toolcall.py — Sanity-check the vLLM endpoint with a tool-call payload.

Checks:
  1. /health endpoint returns 200
  2. /v1/models lists the expected model
  3. A basic completion works
  4. A tool-call request populates the `tool_calls` field in the response
     (this will FAIL silently for Qwen2.5-Coder with --tool-call-parser hermes
      due to a known vLLM issue — the script surfaces the failure clearly)

Exit codes:
  0 — all checks passed (tool_calls populated)
  1 — basic inference works but tool_calls was empty (silent parser failure)
  2 — server unreachable or basic inference failed
"""

import json
import os
import sys
from pathlib import Path
from typing import Any

try:
    from openai import OpenAI
except ImportError:
    print("ERROR: openai package not installed. Run: pip install openai")
    sys.exit(2)

# ---------------------------------------------------------------------------
# Config (read from env or use defaults matching config.env)
# ---------------------------------------------------------------------------
BASE_URL = os.environ.get("VLLM_BASE_URL", "http://localhost:8000/v1")
API_KEY  = os.environ.get("VLLM_API_KEY", "not-needed")
MODEL    = os.environ.get("MODEL_NAME", "Qwen2.5-Coder-32B-Instruct")

# For OpenHands, the model name is prefixed with "openai/"
OH_MODEL = f"openai/{MODEL}"

# ---------------------------------------------------------------------------
# Dummy tool definition
# ---------------------------------------------------------------------------
TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get the current weather for a city.",
            "parameters": {
                "type": "object",
                "properties": {
                    "city": {
                        "type": "string",
                        "description": "The city name",
                    },
                    "unit": {
                        "type": "string",
                        "enum": ["celsius", "fahrenheit"],
                        "description": "Temperature unit",
                    },
                },
                "required": ["city"],
            },
        },
    }
]

TOOL_CALL_MESSAGE = [
    {
        "role": "system",
        "content": "You are a helpful assistant with access to tools. When the user asks about weather, call the get_weather function.",
    },
    {
        "role": "user",
        "content": "What is the weather in San Francisco right now?",
    },
]


def print_section(title: str) -> None:
    print(f"\n{'='*60}")
    print(f"  {title}")
    print('='*60)


def check_health(client: OpenAI) -> bool:
    import urllib.request
    url = BASE_URL.rstrip("/v1").rstrip("/") + "/health"
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            ok = r.status == 200
            print(f"  /health → HTTP {r.status} {'✓' if ok else '✗'}")
            return ok
    except Exception as e:
        print(f"  /health → FAILED: {e}")
        return False


def check_models(client: OpenAI) -> bool:
    try:
        models = client.models.list()
        ids = [m.id for m in models.data]
        print(f"  Models listed: {ids}")
        found = MODEL in ids or any(MODEL in mid for mid in ids)
        print(f"  Expected model '{MODEL}' found: {'✓' if found else '✗'}")
        return True  # List itself working is enough
    except Exception as e:
        print(f"  Model list FAILED: {e}")
        return False


def check_basic_completion(client: OpenAI) -> bool:
    try:
        resp = client.chat.completions.create(
            model=MODEL,
            messages=[{"role": "user", "content": "Say 'hello world' in one word."}],
            max_tokens=32,
            temperature=0.0,
        )
        content = resp.choices[0].message.content or ""
        print(f"  Basic completion: {content.strip()!r}")
        print("  Basic completion: ✓")
        return True
    except Exception as e:
        print(f"  Basic completion FAILED: {e}")
        return False


def check_tool_call(client: OpenAI) -> tuple[bool, dict[str, Any]]:
    """Returns (tool_calls_populated, raw_response_dict)."""
    try:
        resp = client.chat.completions.create(
            model=MODEL,
            messages=TOOL_CALL_MESSAGE,
            tools=TOOLS,
            tool_choice="auto",
            max_tokens=256,
            temperature=0.0,
        )
        msg = resp.choices[0].message
        raw = {
            "finish_reason": resp.choices[0].finish_reason,
            "content": msg.content,
            "tool_calls": [
                {
                    "id": tc.id,
                    "function": {
                        "name": tc.function.name,
                        "arguments": tc.function.arguments,
                    },
                }
                for tc in (msg.tool_calls or [])
            ],
        }

        if msg.tool_calls:
            tc = msg.tool_calls[0]
            print(f"  tool_calls populated: ✓")
            print(f"  Called function: {tc.function.name}")
            try:
                args = json.loads(tc.function.arguments)
                print(f"  Arguments: {args}")
            except json.JSONDecodeError:
                print(f"  Arguments (raw): {tc.function.arguments!r}")
            return True, raw
        else:
            print("  tool_calls populated: ✗  (EMPTY)")
            print(f"  finish_reason: {resp.choices[0].finish_reason}")
            print(f"  content: {msg.content!r}")
            if msg.content and ("```" in msg.content or "<tool_call>" in msg.content):
                print()
                print("  DIAGNOSIS: Model output appears to contain a tool call in text form")
                print("  but the vLLM parser did not convert it to the tool_calls field.")
                print()
                print("  This is a known issue with --tool-call-parser hermes on Qwen2.5-Coder.")
                print("  The model uses a different call format (```json blocks) than hermes expects.")
                print()
                print("  RECOMMENDED FIX: Switch to Qwen3-Coder which uses --tool-call-parser qwen3_coder")
                print("  Set MODEL_FAMILY=qwen3_coder in config.env and re-run.")
            return False, raw
    except Exception as e:
        print(f"  Tool call FAILED with exception: {e}")
        return False, {}


def main() -> int:
    client = OpenAI(base_url=BASE_URL, api_key=API_KEY)

    print_section("1. Health check")
    healthy = check_health(client)
    if not healthy:
        print("\nFATAL: vLLM server not reachable. Is it running?")
        print(f"Expected: {BASE_URL}")
        return 2

    print_section("2. Model listing")
    check_models(client)

    print_section("3. Basic completion")
    basic_ok = check_basic_completion(client)
    if not basic_ok:
        print("\nFATAL: Basic inference failed.")
        return 2

    print_section("4. Tool-call test")
    tool_ok, raw = check_tool_call(client)

    # Write results to file
    out_dir = os.environ.get("RESULTS_DIR", os.path.expanduser("~/baseline-results"))
    run_tag = os.environ.get("RUN_TAG", "latest")
    out_path = Path(out_dir) / run_tag / "toolcall_test.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(
            {
                "base_url": BASE_URL,
                "model": MODEL,
                "tool_calls_populated": tool_ok,
                "raw_response": raw,
            },
            f,
            indent=2,
        )
    print(f"\n  Results written to: {out_path}")

    print_section("Summary")
    print(f"  Basic inference:      {'✓' if basic_ok else '✗'}")
    print(f"  Tool calls populated: {'✓' if tool_ok else '✗'}")
    if not tool_ok:
        print()
        print("  WARN: Evaluations will proceed but tool-calling may be degraded.")
        print("  SWE-bench / TerminalBench results should still be collected as baselines.")
        print("  Inspect toolcall_test.json to understand the parser behavior.")
    print()

    return 0 if tool_ok else 1


if __name__ == "__main__":
    sys.exit(main())
