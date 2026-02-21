#!/bin/bash
# ======================================================================
#  Plannotator Hook — PermissionRequest handler for ExitPlanMode
#
#  Called by Claude Code when exiting plan mode.
#  Reads hook event JSON from stdin, extracts plan, launches the
#  plan review server, and outputs hook decision JSON to stdout.
#
#  Hook protocol:
#    stdin: JSON with tool_input.plan and permission_mode
#    stdout: JSON with hookSpecificOutput (allow/deny decision)
#    stderr: debug messages, URL for user
# ======================================================================

set -uo pipefail

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Extract plan content and permission mode using jq
PLAN_CONTENT=$(echo "$HOOK_INPUT" | jq -r '.tool_input.plan // ""')
PERMISSION_MODE=$(echo "$HOOK_INPUT" | jq -r '.permission_mode // "default"')

if [ -z "$PLAN_CONTENT" ]; then
  echo "Plannotator: No plan content in hook event" >&2
  exit 2
fi

# Write plan to temp file
PLAN_FILE=$(mktemp /tmp/plannotator-plan-XXXXXX.md)
trap 'rm -f "$PLAN_FILE"' EXIT

# Use printf to preserve content faithfully (echo may interpret escapes)
printf '%s' "$PLAN_CONTENT" > "$PLAN_FILE"

# Print URL to stderr so user sees it in terminal
PORT="${PLANNOTATOR_PORT:-19432}"
echo "" >&2
echo "======================================" >&2
echo "  Plan Review" >&2
echo "  Open: http://localhost:${PORT}" >&2
echo "  Waiting for your review..." >&2
echo "======================================" >&2
echo "" >&2

# Run server — blocks until user decides, outputs hook JSON to stdout
exec node /opt/plannotator/server.js \
  --plan-file "$PLAN_FILE" \
  --permission-mode "$PERMISSION_MODE"
