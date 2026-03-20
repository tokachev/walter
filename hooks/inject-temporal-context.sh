#!/usr/bin/env bash
# SessionStart hook: injects temporal context so the model knows
# how stale its training data might be.

CURRENT_DATE=$(date "+%Y-%m-%d %H:%M %Z")
TRAINING_CUTOFF="2025-05-01"

# Calculate months gap
cutoff_epoch=$(date -d "$TRAINING_CUTOFF" "+%s" 2>/dev/null || date -j -f "%Y-%m-%d" "$TRAINING_CUTOFF" "+%s" 2>/dev/null || echo 0)
current_epoch=$(date "+%s")
if [ "$cutoff_epoch" -gt 0 ]; then
  MONTHS_GAP=$(( (current_epoch - cutoff_epoch) / 2592000 ))
else
  MONTHS_GAP="unknown"
fi

cat << EOF
Current date: ${CURRENT_DATE}
Knowledge cutoff: approximately ${TRAINING_CUTOFF}
Time gap: ~${MONTHS_GAP} months of potential changes

HIGH-RISK LIBRARIES (frequent breaking changes):
Apache Airflow, dbt-core, dbt adapters, Snowflake Python connector,
snowflake-sqlalchemy, pandas, SQLAlchemy 2.x, Pydantic v2,
FastAPI, LangChain, Anthropic SDK, OpenAI SDK, Claude Code CLI

VERIFICATION PROTOCOL:
1. For ANY question about versions, APIs, current state — check project files first, then search
2. Never claim "this doesn't exist" without verification
3. If code looks unfamiliar — assume valid modern syntax, not an error
4. Mark uncertain claims: "Based on training (may be outdated)..."
EOF
