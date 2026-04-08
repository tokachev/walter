#!/usr/bin/env bash
# Metric: pytest pass rate 0-100 (higher is better)
# Eval contract: last line = pass rate 0-100 (integer, higher is better)
# Usage: pytest-score.sh [pytest args...]
# Example: pytest-score.sh tests/ -k "not slow"
set -euo pipefail

OUTPUT=$(pytest "$@" --tb=short -q 2>&1 || true)

# Extract summary line: "N passed" and/or "N failed" patterns
PASSED=$(echo "$OUTPUT" | grep -oP '\d+(?= passed)' | tail -1 || echo "0")
FAILED=$(echo "$OUTPUT" | grep -oP '\d+(?= failed)' | tail -1 || echo "0")

TOTAL=$(( PASSED + FAILED ))

if [[ "$TOTAL" -eq 0 ]]; then
    echo "0"
    exit 0
fi

# Integer division is fine for 0-100 range — use awk for rounding
SCORE=$(awk "BEGIN { printf \"%d\", ($PASSED / $TOTAL) * 100 }")
echo "$SCORE"
