"""
circuit_breaker.py — Detect tool call loops and abort.

Pattern: sliding window counter per tool_name.
If the same tool is called >N times in M minutes, trigger circuit breaker.

Config via env vars:
  WALTER_CB_THRESHOLD  — max calls per tool in window (default: 20)
  WALTER_CB_WINDOW     — window in seconds (default: 120)
"""

import os

from audit import read_recent_entries

THRESHOLD = int(os.getenv("WALTER_CB_THRESHOLD", "50"))
WINDOW = int(os.getenv("WALTER_CB_WINDOW", "120"))


def check(tool_name: str) -> tuple[bool, str]:
    """
    Check if a tool call should be allowed.

    Returns:
        (allowed, reason) — True if allowed, False + reason if tripped.
    """
    recent = read_recent_entries(seconds=WINDOW, tool_filter=tool_name)
    count = len(recent)

    if count >= THRESHOLD:
        return False, (
            f"Circuit breaker: {tool_name} called {count} times "
            f"in the last {WINDOW}s (threshold: {THRESHOLD}). "
            f"Possible loop detected — aborting to prevent runaway costs."
        )

    return True, ""
