#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  Guardrails Hook — PreToolUse hook for audit log + circuit breaker
#
#  Called by Claude Code via native hooks (settings.json).
#  Runs on EVERY tool call (matcher: ".*").
#
#  Hook protocol (native):
#    stdin: JSON with tool_name, tool_input, session_id, etc.
#    exit 0 + no output: allow
#    exit 0 + JSON with permissionDecision="deny": block
# ══════════════════════════════════════════════════════════════

set -uo pipefail

GUARDRAILS_DIR="/opt/guardrails"

# Read hook input from stdin (can be large for Write/Edit tools)
HOOK_INPUT=$(cat)

# Pass entire hook JSON via stdin to Python (avoids ARG_MAX limits)
RESULT=$(printf '%s' "$HOOK_INPUT" | timeout 5 python3 "$GUARDRAILS_DIR/hook_check.py" 2>/dev/null)
EXIT_CODE=$?

# timeout exit code 124 = timed out; treat as allow (fail-open)
if [ $EXIT_CODE -eq 124 ]; then
    exit 0
fi

if [ $EXIT_CODE -eq 1 ] && [ -n "$RESULT" ]; then
    # Circuit breaker or budget tripped — block
    REASON=$(echo "$RESULT" | head -1)
    jq -n \
        --arg reason "$REASON" \
        '{
            hookSpecificOutput: {
                hookEventName: "PreToolUse",
                permissionDecision: "deny",
                permissionDecisionReason: $reason
            }
        }'
    exit 0
fi

# All clear
exit 0
