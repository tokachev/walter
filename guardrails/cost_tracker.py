"""
cost_tracker.py — Track token usage and estimated cost per agent run.

Pricing (Anthropic, as of 2025):
  claude-opus-4      — $15/MTok input, $75/MTok output
  claude-sonnet-4    — $3/MTok input, $15/MTok output
  claude-haiku-4     — $0.80/MTok input, $4/MTok output

Config via env vars:
  WALTER_COST_BUDGET     — max cost in USD per run (default: 5.0)
  WALTER_COST_LOG        — path to cost accumulator file

On budget exceeded: writes alert file + returns block signal.
"""

import json
import os
import time
from pathlib import Path

COST_BUDGET = float(os.getenv("WALTER_COST_BUDGET", "5.0"))
COST_LOG = os.getenv("WALTER_COST_LOG", "/var/log/walter/cost.json")
ALERT_FILE = os.getenv("WALTER_COST_ALERT", "/var/log/walter/budget_exceeded.alert")

# Pricing per million tokens (input, output)
MODEL_PRICING = {
    "claude-opus-4": (15.0, 75.0),
    "claude-opus-4-6": (15.0, 75.0),
    "claude-sonnet-4": (3.0, 15.0),
    "claude-sonnet-4-6": (3.0, 15.0),
    "claude-sonnet-4-20250514": (3.0, 15.0),
    "claude-haiku-4": (0.80, 4.0),
    "claude-haiku-4-5-20251001": (0.80, 4.0),
}

# Fallback pricing if model not recognized
DEFAULT_PRICING = (15.0, 75.0)  # assume most expensive


def _load_state() -> dict:
    try:
        return json.loads(Path(COST_LOG).read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {"total_input_tokens": 0, "total_output_tokens": 0, "total_cost_usd": 0.0, "calls": 0}


def _save_state(state: dict):
    Path(COST_LOG).parent.mkdir(parents=True, exist_ok=True)
    Path(COST_LOG).write_text(json.dumps(state, indent=2))


def estimate_cost(model: str, input_tokens: int, output_tokens: int) -> float:
    """Estimate cost in USD for a single API call."""
    pricing = DEFAULT_PRICING
    for key, val in MODEL_PRICING.items():
        if key in model.lower():
            pricing = val
            break

    input_cost = (input_tokens / 1_000_000) * pricing[0]
    output_cost = (output_tokens / 1_000_000) * pricing[1]
    return input_cost + output_cost


def record_usage(model: str, input_tokens: int, output_tokens: int) -> dict:
    """
    Record token usage and check budget.

    Returns dict with:
        cost_usd: cost of this call
        total_cost_usd: cumulative cost
        budget_exceeded: True if over budget
        budget_remaining: USD remaining
    """
    cost = estimate_cost(model, input_tokens, output_tokens)
    state = _load_state()

    state["total_input_tokens"] += input_tokens
    state["total_output_tokens"] += output_tokens
    state["total_cost_usd"] += cost
    state["calls"] += 1
    state["last_update"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")

    _save_state(state)

    exceeded = state["total_cost_usd"] > COST_BUDGET

    if exceeded:
        _write_alert(state)

    return {
        "cost_usd": round(cost, 4),
        "total_cost_usd": round(state["total_cost_usd"], 4),
        "budget_exceeded": exceeded,
        "budget_remaining": round(max(0, COST_BUDGET - state["total_cost_usd"]), 4),
    }


def _write_alert(state: dict):
    """Write alert file when budget is exceeded."""
    Path(ALERT_FILE).parent.mkdir(parents=True, exist_ok=True)
    alert = {
        "alert": "BUDGET_EXCEEDED",
        "budget_usd": COST_BUDGET,
        "actual_usd": round(state["total_cost_usd"], 4),
        "total_calls": state["calls"],
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }
    Path(ALERT_FILE).write_text(json.dumps(alert, indent=2))


def get_status() -> dict:
    """Get current cost tracking status."""
    state = _load_state()
    return {
        "total_input_tokens": state["total_input_tokens"],
        "total_output_tokens": state["total_output_tokens"],
        "total_cost_usd": round(state["total_cost_usd"], 4),
        "budget_usd": COST_BUDGET,
        "budget_remaining": round(max(0, COST_BUDGET - state["total_cost_usd"]), 4),
        "budget_exceeded": state["total_cost_usd"] > COST_BUDGET,
        "calls": state["calls"],
    }


def is_budget_exceeded() -> bool:
    """Quick check if budget is exceeded."""
    state = _load_state()
    return state["total_cost_usd"] > COST_BUDGET
