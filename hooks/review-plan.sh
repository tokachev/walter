#!/bin/bash
# review-plan — open a plan file in plannotator web UI for review
# Usage: review-plan <plan-file.md>
#        review-plan              (auto-finds latest plan in .planning/phases/)
#
# Flow:
#   1. Opens plan in plannotator browser UI on PLANNOTATOR_PORT
#   2. User reviews, annotates, clicks approve/deny
#   3. Outputs decision + feedback as plain text for Claude to read

set -euo pipefail

if [ -n "${1:-}" ]; then
  PLAN_FILE="$1"
else
  PLAN_FILE=$(ls -t .planning/phases/*-PLAN.md 2>/dev/null | head -1)
  if [ -z "$PLAN_FILE" ]; then
    echo "Usage: review-plan <plan-file.md>" >&2
    echo "No plan files found in .planning/phases/" >&2
    exit 1
  fi
  echo "Auto-selected: $PLAN_FILE"
fi

if [ ! -f "$PLAN_FILE" ]; then
  echo "File not found: $PLAN_FILE" >&2
  exit 1
fi

# Hook mode: pipe plan as JSON to plannotator stdin → starts local HTTP server
PLAN_CONTENT=$(cat "$PLAN_FILE")
OUTPUT=$(printf '%s' "$PLAN_CONTENT" | jq -Rs '{tool_input: {plan: .}, permission_mode: "plan"}' | plannotator 2>/dev/null) || true

# Parse plannotator's hook JSON output into human-readable text
BEHAVIOR=$(printf '%s' "$OUTPUT" | jq -r '.hookSpecificOutput.decision.behavior // empty' 2>/dev/null)
FEEDBACK=$(printf '%s' "$OUTPUT" | jq -r '.hookSpecificOutput.decision.message // empty' 2>/dev/null)

case "$BEHAVIOR" in
  allow)
    echo "APPROVED: $PLAN_FILE"
    [ -n "$FEEDBACK" ] && echo -e "\nFeedback:\n$FEEDBACK"
    ;;
  deny)
    echo "DENIED: $PLAN_FILE"
    [ -n "$FEEDBACK" ] && echo -e "\nFeedback:\n$FEEDBACK"
    ;;
  *)
    echo "Review ended without decision for: $PLAN_FILE"
    [ -n "$OUTPUT" ] && echo -e "\nRaw output:\n$OUTPUT"
    ;;
esac
