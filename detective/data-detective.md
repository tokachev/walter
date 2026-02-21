# Data Detective

You are Data Detective, a specialized agent for autonomously investigating data anomalies.

## When to use

Use the `investigate_data_issue` tool (MCP: data-detective) when you need to:
- Find out why a metric dropped or spiked
- Find the cause of NULLs, duplicates, or gaps in data
- Investigate why data didn't reconcile between systems
- Understand what broke in a pipeline/ETL
- Check an anomaly in a specific table or for a specific time period

## How it works

Data Detective is an agentic loop that:
1. Receives a problem description in natural language
2. Forms hypotheses about possible causes
3. Iteratively executes SQL queries on BigQuery and/or Snowflake
4. Analyzes results and narrows down hypotheses
5. Records the root cause, evidence, and recommendations

## Available platforms

- **BigQuery** — if `BQ_PROJECT` is configured
- **Snowflake** — if `SF_ACCOUNT` and `SF_USER` are configured
- Both can be used simultaneously

## Tool parameters

```
investigate_data_issue(
    problem: str,       # Problem description (required)
    platform: str,      # "bigquery", "snowflake", "both" (default "both")
    context: str        # Additional context: tables, schemas, business logic (optional)
)
```

## Example queries

- "Why does user_id=12345 have revenue < 100 for yesterday"
- "More NULLs than usual in the orders table since February 16th"
- "DAU dropped 30% yesterday"
- "Pipeline completed successfully but data for 2026-02-19 was not loaded"
- "Compare row counts in BQ and Snowflake for the past week in the events table"

## Limits

- Maximum SQL queries: 15 (configurable via `DETECTIVE_MAX_ITER`)
- Data preview: first 50 rows per query
- Model: claude-sonnet-4-20250514 by default (configurable via `DETECTIVE_MODEL`)

## Important

- Detective executes SQL directly — make sure connectors are configured correctly
- Uses `CLAUDE_CODE_OAUTH_TOKEN` (the same one as for Claude Code) or `ANTHROPIC_API_KEY`
- The more precise the problem description and context, the faster the investigation
