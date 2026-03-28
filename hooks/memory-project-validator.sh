#!/bin/bash
# PreToolUse hook: validate --project flag in memory_tool save commands
# Blocks if --project doesn't match .memory_project in workspace root.
set -uo pipefail

HOOK_INPUT=$(cat)

COMMAND=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# Only check memory.py save commands with --project
echo "$COMMAND" | grep -q 'memory.py save' || exit 0
echo "$COMMAND" | grep -q '\-\-project' || exit 0

# Extract --project value from command
PROJECT_FLAG=$(echo "$COMMAND" | grep -oP '(?<=--project\s)[^\s]+' 2>/dev/null || \
               echo "$COMMAND" | sed -n 's/.*--project[= ]\([^ ]*\).*/\1/p' 2>/dev/null)
[ -z "$PROJECT_FLAG" ] && exit 0

# Read expected project from workspace
EXPECTED=""
[ -f /workspace/.memory_project ] && EXPECTED=$(cat /workspace/.memory_project | tr -d '[:space:]')
[ -z "$EXPECTED" ] && exit 0

if [ "$PROJECT_FLAG" != "$EXPECTED" ]; then
    jq -n \
        --arg reason "Memory project mismatch: --project $PROJECT_FLAG but .memory_project says $EXPECTED. Fix the --project flag." \
        '{
            hookSpecificOutput: {
                hookEventName: "PreToolUse",
                permissionDecision: "deny",
                permissionDecisionReason: $reason
            }
        }'
fi

exit 0
