#!/usr/bin/env bash
# Metric: elapsed seconds (lower is better)
# Eval contract: last line = elapsed seconds (integer, lower is better)
# Usage: sql-time.sh <path-to-sql-file>
set -euo pipefail

SQL_FILE="${1:?Usage: sql-time.sh <path-to-sql-file>}"

if [[ ! -f "$SQL_FILE" ]]; then
    echo "Error: SQL file not found: $SQL_FILE" >&2
    exit 1
fi

START=$SECONDS
bq query --use_legacy_sql=false --format=json < "$SQL_FILE" > /dev/null
ELAPSED=$(( SECONDS - START ))

echo "$ELAPSED"
