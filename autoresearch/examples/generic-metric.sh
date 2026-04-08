#!/usr/bin/env bash
# Eval contract: last line = numeric metric extracted from command output
# Accepts command and all its arguments as "$@", executes it, finds the last
# line matching a number (integer or float, possibly negative), echoes it.
# Exits 1 if no numeric line is found.
# Usage: generic-metric.sh <command> [args...]
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: generic-metric.sh <command> [args...]" >&2
    exit 1
fi

OUTPUT=$("$@" 2>&1)

# Find last line that is purely a number (int or float, optional leading minus)
METRIC=$(echo "$OUTPUT" | grep -oP '^-?\d+(\.\d+)?$' | tail -1 || true)

if [[ -z "$METRIC" ]]; then
    echo "Error: no numeric line found in output of: $*" >&2
    echo "Output was:" >&2
    echo "$OUTPUT" >&2
    exit 1
fi

echo "$METRIC"
