#!/usr/bin/env python3
"""
hook_check.py — Called by hook.sh to perform audit logging and circuit breaker check.

Reads the full hook JSON from stdin (avoids ARG_MAX issues with large tool inputs).

Exit codes:
    0 = allow
    1 = block (reason on stdout)
"""

import json
import sys
import os

sys.path.insert(0, os.path.dirname(__file__))

from audit import log_tool_call
from circuit_breaker import check as cb_check
from cost_tracker import is_budget_exceeded


def main():
    try:
        hook_json = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)  # Can't parse — fail-open

    tool_name = hook_json.get("tool_name", "")
    session_id = hook_json.get("session_id", "")
    # Hash the input for audit, don't store raw (could be huge)
    tool_input = hook_json.get("tool_input", {})

    if not tool_name:
        sys.exit(0)

    # 1. Check circuit breaker
    allowed, reason = cb_check(tool_name)
    if not allowed:
        log_tool_call(
            tool_name, tool_input,
            session_id=session_id, blocked=True, block_reason=reason,
        )
        print(reason)
        sys.exit(1)

    # 2. Check cost budget
    if is_budget_exceeded():
        reason = (
            f"Cost budget exceeded (limit: ${os.getenv('WALTER_COST_BUDGET', '5.0')}). "
            "Agent run stopped to prevent runaway costs. "
            "Check /var/log/walter/cost.json for details."
        )
        log_tool_call(
            tool_name, tool_input,
            session_id=session_id, blocked=True, block_reason=reason,
        )
        print(reason)
        sys.exit(1)

    # 3. Log the tool call (audit)
    log_tool_call(tool_name, tool_input, session_id=session_id)

    sys.exit(0)


if __name__ == "__main__":
    main()
