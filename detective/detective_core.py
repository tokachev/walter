"""
detective_core.py — investigation logic without UI/terminal output
Used by both the CLI (detective.py) and the MCP server (mcp_server.py)
"""

import os
import json
from datetime import datetime
from typing import Optional
import anthropic

MODEL = os.getenv("DETECTIVE_MODEL", "claude-opus-4-6")
MAX_ITERATIONS = int(os.getenv("DETECTIVE_MAX_ITER", "15"))
MAX_TOKENS = int(os.getenv("DETECTIVE_MAX_TOKENS", "8000"))

from connectors import QueryResult

# ─── Tools definition (shared) ───────────────────────────────────────────────

TOOLS = [
    {
        "name": "run_sql",
        "description": (
            "Execute an SQL query on the specified platform (bigquery or snowflake). "
            "Use to verify hypotheses, explore data, compare time periods. "
            "Always add LIMIT to avoid pulling millions of rows unnecessarily."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "sql": {"type": "string", "description": "SQL query"},
                "platform": {
                    "type": "string",
                    "enum": ["bigquery", "snowflake", "both"],
                    "description": "Platform"
                },
                "description": {"type": "string", "description": "What this query is checking"}
            },
            "required": ["sql", "platform", "description"]
        }
    },
    {
        "name": "get_schema",
        "description": "Get the schema of a table (columns, types). Use before writing SQL.",
        "input_schema": {
            "type": "object",
            "properties": {
                "table": {"type": "string", "description": "Table name: dataset.table or db.schema.table"},
                "platform": {"type": "string", "enum": ["bigquery", "snowflake"]}
            },
            "required": ["table", "platform"]
        }
    },
    {
        "name": "list_tables",
        "description": "List tables in a dataset/schema. Use to search for tables.",
        "input_schema": {
            "type": "object",
            "properties": {
                "dataset": {"type": "string", "description": "Dataset (BQ) or schema (Snowflake)"},
                "platform": {"type": "string", "enum": ["bigquery", "snowflake"]},
                "filter": {"type": "string", "description": "Filter by name (substring)"}
            },
            "required": ["dataset", "platform"]
        }
    },
    {
        "name": "conclude",
        "description": "Record final conclusion. Call when root cause is found or hypotheses are exhausted.",
        "input_schema": {
            "type": "object",
            "properties": {
                "status": {
                    "type": "string",
                    "enum": ["found", "inconclusive", "no_anomaly"],
                    "description": "found/inconclusive/no_anomaly"
                },
                "root_cause": {"type": "string"},
                "evidence": {"type": "array", "items": {"type": "string"}},
                "recommendation": {"type": "string"},
                "investigated_hypotheses": {"type": "array", "items": {"type": "string"}}
            },
            "required": ["status", "evidence", "recommendation", "investigated_hypotheses"]
        }
    }
]


def build_system_prompt(available_platforms: list[str]) -> str:
    today = datetime.now().strftime("%Y-%m-%d")
    platforms_str = " and ".join(p.upper() for p in available_platforms)
    return f"""You are Data Detective, a specialized agent for investigating data anomalies.

Today's date: {today}
Available platforms: {platforms_str}

## Methodology

1. **Confirm the fact** — first verify that the anomaly is real
2. **Hypotheses** (in order of likelihood):
   - Upstream: source stopped sending / changed format
   - ETL/Pipeline: job failed, partial load, timeout
   - Business logic: calculation logic changed
   - Data: duplicates, NULLs, data type issues
   - Infrastructure: access permissions, network
3. **Dig where you found something** — compare periods before/after
4. **Call conclude** when root cause is found or hypotheses are exhausted

## SQL rules
- LIMIT always (don't pull millions of rows)
- COUNT(*) vs COUNT(col) = number of NULLs
- For comparison: current period vs average over 7-30 days
- Query limit: {MAX_ITERATIONS}
"""


class ToolExecutor:
    def __init__(self, connectors: dict):
        self.connectors = connectors
        self.query_count = 0
        self.conclusion = None
        self.log = []  # log for MCP mode

    def execute(self, tool_name: str, tool_input: dict) -> str:
        if tool_name == "run_sql":
            return self._run_sql(**tool_input)
        elif tool_name == "get_schema":
            return self._get_schema(**tool_input)
        elif tool_name == "list_tables":
            return self._list_tables(**tool_input)
        elif tool_name == "conclude":
            self.conclusion = tool_input
            return "Conclusion recorded."
        return f"Unknown tool: {tool_name}"

    def _run_sql(self, sql: str, platform: str, description: str) -> str:
        self.query_count += 1
        self.log.append(f"[SQL {self.query_count}] {description}")

        results = []
        platforms = ["bigquery", "snowflake"] if platform == "both" else [platform]

        for p in platforms:
            if p not in self.connectors:
                results.append(f"[{p.upper()}] Connector not configured")
                continue
            result: QueryResult = self.connectors[p].execute(sql)
            if result.error:
                output = f"[{p.upper()}] ERROR: {result.error}"
            else:
                rows_preview = result.rows[:50]
                output = f"[{p.upper()}] Rows: {result.row_count}\n"
                if result.columns:
                    output += f"Columns: {', '.join(result.columns)}\n"
                output += f"Data:\n{json.dumps(rows_preview, default=str, ensure_ascii=False, indent=2)}"
                if result.row_count > 50:
                    output += f"\n... (showing first 50 of {result.row_count})"
            results.append(output)

        return "\n\n".join(results)

    def _get_schema(self, table: str, platform: str) -> str:
        self.log.append(f"[Schema] {table} ({platform})")
        if platform not in self.connectors:
            return f"Connector {platform} not configured"
        result = self.connectors[platform].get_schema(table)
        if result.error:
            return f"Error: {result.error}"
        return json.dumps(result.rows, default=str, ensure_ascii=False, indent=2)

    def _list_tables(self, dataset: str, platform: str, filter: str = None) -> str:
        self.log.append(f"[Tables] {dataset} ({platform})")
        if platform not in self.connectors:
            return f"Connector {platform} not configured"
        result = self.connectors[platform].list_tables(dataset, filter_str=filter)
        if result.error:
            return f"Error: {result.error}"
        return json.dumps(result.rows, default=str, ensure_ascii=False, indent=2)


def run_investigation(problem: str, available_platforms: list[str], connectors: dict) -> dict:
    """
    Runs the investigation. Returns a dict with fields:
    - conclusion: dict (from conclude tool)
    - log: list[str] (what was executed)
    - query_count: int
    - thinking: list[str] (text blocks from the agent)
    """
    api_key = os.getenv("ANTHROPIC_API_KEY")
    oauth_token = os.getenv("CLAUDE_CODE_OAUTH_TOKEN")
    if api_key:
        client = anthropic.Anthropic(api_key=api_key)
    elif oauth_token:
        client = anthropic.Anthropic(auth_token=oauth_token)
    else:
        raise ValueError("Required: ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN")
    executor = ToolExecutor(connectors)

    system_prompt = build_system_prompt(available_platforms)
    messages = [{"role": "user", "content": problem}]
    thinking_blocks = []

    iteration = 0
    while iteration < MAX_ITERATIONS * 3:
        iteration += 1

        response = client.messages.create(
            model=MODEL,
            max_tokens=MAX_TOKENS,
            system=system_prompt,
            tools=TOOLS,
            messages=messages,
        )

        messages.append({"role": "assistant", "content": response.content})

        tool_calls = []
        for block in response.content:
            if block.type == "text" and block.text.strip():
                thinking_blocks.append(block.text.strip())
            elif block.type == "tool_use":
                tool_calls.append(block)

        if not tool_calls:
            if executor.conclusion:
                break
            messages.append({"role": "user", "content": "Call conclude for the final conclusion."})
            continue

        tool_results = []
        for tc in tool_calls:
            result = executor.execute(tc.name, tc.input)
            tool_results.append({
                "type": "tool_result",
                "tool_use_id": tc.id,
                "content": result
            })
            if tc.name == "conclude":
                break

        messages.append({"role": "user", "content": tool_results})

        if executor.conclusion:
            break

        if executor.query_count >= MAX_ITERATIONS:
            messages.append({
                "role": "user",
                "content": f"Used {executor.query_count}/{MAX_ITERATIONS} queries. Summarize and call conclude."
            })

    return {
        "conclusion": executor.conclusion,
        "log": executor.log,
        "query_count": executor.query_count,
        "thinking": thinking_blocks,
    }


def format_result_for_mcp(problem: str, result: dict) -> str:
    """Formats the investigation result into readable text for MCP."""
    lines = []
    lines.append(f"# 🔍 Data Detective — Investigation result\n")
    lines.append(f"**Problem:** {problem}\n")
    lines.append(f"**Queries executed:** {result['query_count']}\n")

    if result["log"]:
        lines.append("**Investigation log:**")
        for entry in result["log"]:
            lines.append(f"  • {entry}")
        lines.append("")

    if result["thinking"]:
        lines.append("**Agent analysis:**")
        for thought in result["thinking"]:
            # Take the first 300 characters of each thinking block
            short = thought[:300] + "..." if len(thought) > 300 else thought
            lines.append(f"  {short}")
        lines.append("")

    conclusion = result.get("conclusion")
    if not conclusion:
        lines.append("⚠️  Agent did not provide a final conclusion.")
        return "\n".join(lines)

    status = conclusion.get("status", "inconclusive")
    icons = {"found": "🎯", "inconclusive": "🔍", "no_anomaly": "✅"}
    lines.append(f"## {icons.get(status, '❓')} Conclusion\n")

    if conclusion.get("root_cause"):
        lines.append(f"**Root Cause:**\n{conclusion['root_cause']}\n")

    if conclusion.get("evidence"):
        lines.append("**Evidence:**")
        for e in conclusion["evidence"]:
            lines.append(f"  • {e}")
        lines.append("")

    if conclusion.get("investigated_hypotheses"):
        lines.append("**Investigated hypotheses:**")
        for h in conclusion["investigated_hypotheses"]:
            lines.append(f"  • {h}")
        lines.append("")

    if conclusion.get("recommendation"):
        lines.append(f"**Recommendation:**\n{conclusion['recommendation']}")

    return "\n".join(lines)


def investigate_and_capture(problem: str, available_platforms: list[str], connectors: dict) -> str:
    """Runs the investigation and returns formatted text. For the MCP server."""
    result = run_investigation(problem, available_platforms, connectors)
    return format_result_for_mcp(problem, result)
