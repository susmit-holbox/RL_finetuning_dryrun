#!/usr/bin/env python3
"""
05_test_endpoint.py — Sanity-check the DashScope OpenAI-compatible endpoint.

Checks:
  1. /v1/models lists at least one model (some DashScope regions don't expose
     this — non-fatal, surfaced as a warning).
  2. A basic chat completion against MODEL_NAME succeeds.
  3. A tool-call request populates the `tool_calls` field in the response
     (informational only — Terminus parses commands from text, not from
     OpenAI tool_calls, so a degraded tool_calls field does NOT block the
     evaluation).

Exit codes:
  0 — basic completion works AND tool_calls populated
  1 — basic completion works but tool_calls was empty (informational)
  2 — basic completion failed (the run cannot proceed)
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
# Config (read from env)
# ---------------------------------------------------------------------------
BASE_URL = os.environ.get("DASHSCOPE_BASE_URL") or os.environ.get("VLLM_BASE_URL")
API_KEY  = os.environ.get("DASHSCOPE_API_KEY") or os.environ.get("VLLM_API_KEY", "")
MODEL    = os.environ.get("MODEL_NAME", "qwen3.7-max")

if not BASE_URL:
    print("ERROR: DASHSCOPE_BASE_URL not set in env")
    sys.exit(2)
if not API_KEY:
    print("ERROR: DASHSCOPE_API_KEY not set in env")
    sys.exit(2)

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
                    "city": {"type": "string", "description": "The city name"},
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


def check_models(client: OpenAI) -> bool:
    try:
        models = client.models.list()
        ids = [m.id for m in models.data]
        print(f"  Models listed: {ids[:10]}{'…' if len(ids) > 10 else ''}")
        found = MODEL in ids or any(MODEL in mid for mid in ids)
        print(f"  Requested model '{MODEL}' advertised: {'✓' if found else '? (not in /v1/models — may still work)'}")
        return True
    except Exception as e:
        print(f"  Model list not available ({e}) — non-fatal on DashScope")
        return True


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

        print("  tool_calls populated: ✗  (EMPTY)")
        print(f"  finish_reason: {resp.choices[0].finish_reason}")
        print(f"  content: {msg.content!r}")
        print()
        print("  Informational only — Terminus parses commands from TEXT,")
        print("  not from OpenAI tool_calls, so the evaluation will proceed.")
        return False, raw
    except Exception as e:
        print(f"  Tool call FAILED with exception: {e}")
        return False, {}


def main() -> int:
    print(f"  Base URL: {BASE_URL}")
    print(f"  Model:    {MODEL}")
    client = OpenAI(base_url=BASE_URL, api_key=API_KEY)

    print_section("1. Model listing")
    check_models(client)

    print_section("2. Basic completion")
    basic_ok = check_basic_completion(client)
    if not basic_ok:
        print("\nFATAL: Basic inference failed — check DASHSCOPE_API_KEY and DASHSCOPE_BASE_URL.")
        return 2

    print_section("3. Tool-call test (informational)")
    tool_ok, raw = check_tool_call(client)

    out_dir = os.environ.get("RESULTS_DIR", os.path.expanduser("~/baseline-results"))
    run_tag = os.environ.get("RUN_TAG", "latest")
    out_path = Path(out_dir) / run_tag / "endpoint_test.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(
            {
                "base_url": BASE_URL,
                "model": MODEL,
                "basic_completion_ok": basic_ok,
                "tool_calls_populated": tool_ok,
                "raw_response": raw,
            },
            f,
            indent=2,
        )
    print(f"\n  Results written to: {out_path}")

    print_section("Summary")
    print(f"  Basic inference:      {'✓' if basic_ok else '✗'}")
    print(f"  Tool calls populated: {'✓' if tool_ok else '✗ (informational)'}")
    print()

    return 0 if tool_ok else 1


if __name__ == "__main__":
    sys.exit(main())
