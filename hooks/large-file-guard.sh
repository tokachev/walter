#!/bin/bash
# PreToolUse hook: block Read on large files without offset/limit
# Forces Claude to use Grep + targeted Read instead of reading entire large files.
set -uo pipefail

HOOK_INPUT=$(cat)

FILE_PATH=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

# If offset or limit is set, allow — Claude is already reading selectively
OFFSET=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.offset // empty' 2>/dev/null)
LIMIT=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.limit // empty' 2>/dev/null)
[ -n "$OFFSET" ] || [ -n "$LIMIT" ] && exit 0

# Check file exists and count lines
[ -f "$FILE_PATH" ] || exit 0
LINE_COUNT=$(wc -l < "$FILE_PATH" 2>/dev/null || echo 0)

if [ "$LINE_COUNT" -gt 500 ]; then
    jq -n \
        --arg reason "File $FILE_PATH has $LINE_COUNT lines. Use Grep to find the relevant section, then Read with offset/limit. Do not read large files in full." \
        '{
            hookSpecificOutput: {
                hookEventName: "PreToolUse",
                permissionDecision: "deny",
                permissionDecisionReason: $reason
            }
        }'
fi

exit 0
