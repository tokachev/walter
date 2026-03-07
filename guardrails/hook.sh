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

# Read hook input
HOOK_INPUT=$(cat)

# Extract fields
TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")
TOOL_INPUT=$(echo "$HOOK_INPUT" | jq -c '.tool_input // {}' 2>/dev/null || echo "{}")

# Run guardrails check (audit + circuit breaker)
RESULT=$(python3 "$GUARDRAILS_DIR/hook_check.py" "$TOOL_NAME" "$SESSION_ID" "$TOOL_INPUT" 2>/dev/null)
EXIT_CODE=$?

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
