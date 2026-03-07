"""
detective_core.py — investigation logic using claude CLI for LLM calls.
Uses Claude Code's auth (OAuth) — no separate API key needed.
"""

import os
import re
import json
import subprocess
from datetime import datetime
from typing import Optional

from connectors import QueryResult

MODEL = os.getenv("DETECTIVE_MODEL", "claude-sonnet-4-20250514")
MAX_ITERATIONS = int(os.getenv("DETECTIVE_MAX_ITER", "15"))

# ─── Tools description (prompt-based tool use) ───────────────────────────────

TOOLS_PROMPT = """You have these investigation tools. To use one, output a fenced JSON block.
Do NOT use any other tools (no Bash, no Read, etc.) — ONLY these:

1. **run_sql** — Execute SQL query
   ```json
   {"tool": "run_sql", "input": {"sql": "SELECT ...", "platform": "bigquery|snowflake|both", "description": "what this checks"}}
   ```

2. **get_schema** — Get table columns and types
   ```json
   {"tool": "get_schema", "input": {"table": "dataset.table", "platform": "bigquery|snowflake"}}
   ```

3. **list_tables** — List tables in a dataset/schema
   ```json
   {"tool": "list_tables", "input": {"dataset": "name", "platform": "bigquery|snowflake"}}
   ```

4. **conclude** — Final conclusion (MUST call when done)
   ```json
   {"tool": "conclude", "input": {"status": "found|inconclusive|no_anomaly", "root_cause": "...", "evidence": ["..."], "recommendation": "...", "investigated_hypotheses": ["..."]}}
   ```

Rules:
- Output EXACTLY ONE tool call per response as a fenced ```json block
- Think step by step BEFORE the JSON block
- Always LIMIT SQL queries
- Call conclude when done or hypotheses exhausted
"""


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
{TOOLS_PROMPT}"""


# ─── Tool executor (unchanged — handles SQL/schema/tables) ──────────────────

class ToolExecutor:
    def __init__(self, connectors: dict):
        self.connectors = connectors
        self.query_count = 0
        self.conclusion = None
        self.log = []

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
        # SQL guardrail: block destructive operations
        from sql_guard_check import check_sql_safety
        safety_error = check_sql_safety(sql)
        if safety_error:
            self.log.append(f"[BLOCKED] {description} — {safety_error}")
            return f"BLOCKED: {safety_error}"

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


# ─── Claude CLI integration ─────────────────────────────────────────────────

def _try_record_cost(raw_output: str):
    """Try to extract token usage from claude CLI JSON output and record cost."""
    try:
        import sys
        sys.path.insert(0, "/opt/guardrails")
        from cost_tracker import record_usage

        data = json.loads(raw_output)
        usage = data.get("usage", {})
        input_tokens = usage.get("input_tokens", 0)
        output_tokens = usage.get("output_tokens", 0)
        if input_tokens or output_tokens:
            result = record_usage(MODEL, input_tokens, output_tokens)
            if result.get("budget_exceeded"):
                raise RuntimeError(
                    f"Cost budget exceeded: ${result['total_cost_usd']} spent. "
                    "Stopping investigation."
                )
    except (ImportError, json.JSONDecodeError, KeyError):
        pass  # Cost tracking unavailable or non-JSON output — continue


def call_claude(prompt: str) -> str:
    """Call claude CLI in print mode with cost tracking."""
    result = subprocess.run(
        ["claude", "-p", "--model", MODEL, "--max-turns", "1",
         "--output-format", "json"],
        input=prompt,
        capture_output=True,
        text=True,
        timeout=180,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"claude CLI error (exit {result.returncode}): {result.stderr[:500]}"
        )

    raw = result.stdout.strip()

    # Try to record cost from JSON response
    _try_record_cost(raw)

    # Extract text content from JSON wrapper
    # claude CLI --output-format json returns: {"result": "<text>", "usage": {...}, ...}
    try:
        data = json.loads(raw)
        if isinstance(data, dict) and "result" in data:
            return str(data["result"])
    except (json.JSONDecodeError, ValueError):
        pass

    # Fallback: return raw output (shouldn't happen with valid JSON mode)
    return raw


def parse_action(response: str) -> Optional[dict]:
    """Extract tool call JSON from Claude's response."""
    # Strategy 1: JSON in fenced code blocks
    for match in re.finditer(r'```(?:json)?\s*\n?(.*?)\n?\s*```', response, re.DOTALL):
        try:
            data = json.loads(match.group(1).strip())
            if isinstance(data, dict) and "tool" in data:
                return data
        except (json.JSONDecodeError, ValueError):
            continue

    # Strategy 2: brace-matching for top-level JSON objects
    depth = 0
    start = None
    for i, ch in enumerate(response):
        if ch == '{':
            if depth == 0:
                start = i
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0 and start is not None:
                try:
                    data = json.loads(response[start:i + 1])
                    if isinstance(data, dict) and "tool" in data:
                        return data
                except (json.JSONDecodeError, ValueError):
                    pass
                start = None

    return None


def build_iteration_prompt(
    system: str, problem: str, history: list, force_conclude: bool = False
) -> str:
    """Build a full prompt for one iteration of the investigation."""
    parts = [system]
    parts.append(f"\n## Problem\n{problem}\n")

    if history:
        parts.append("## Investigation log\n")
        for i, step in enumerate(history, 1):
            if step.get("type") == "thinking":
                parts.append(f"**Step {i} — Analysis:**\n{step['text'][:500]}\n")
            elif step.get("type") == "tool_result":
                input_str = json.dumps(step["input"], ensure_ascii=False)
                parts.append(
                    f"**Step {i} — {step['tool']}({input_str}):**\n"
                    f"```\n{step['result'][:2000]}\n```\n"
                )

    query_count = sum(
        1 for h in history
        if h.get("type") == "tool_result" and h.get("tool") != "conclude"
    )
    remaining = MAX_ITERATIONS - query_count
    parts.append(f"\nQueries used: {query_count}/{MAX_ITERATIONS}")

    if force_conclude or remaining <= 0:
        parts.append(
            "\n**Query limit reached. You MUST call `conclude` now with your best assessment.**"
        )
    elif remaining <= 3:
        parts.append(f"\nOnly {remaining} queries left. Start wrapping up.")

    parts.append("\nWhat is your next investigation step? Think, then output your tool call.")
    return "\n".join(parts)


# ─── Main investigation loop ────────────────────────────────────────────────

def run_investigation(
    problem: str, available_platforms: list[str], connectors: dict
) -> dict:
    """
    Runs the investigation using claude CLI for reasoning.
    Returns a dict with: conclusion, log, query_count, thinking.
    """
    executor = ToolExecutor(connectors)
    system = build_system_prompt(available_platforms)
    history = []
    thinking_blocks = []
    retries_without_action = 0

    for iteration in range(MAX_ITERATIONS * 3):
        force_conclude = executor.query_count >= MAX_ITERATIONS
        prompt = build_iteration_prompt(system, problem, history, force_conclude)

        try:
            response = call_claude(prompt)
        except Exception as e:
            thinking_blocks.append(f"Error calling Claude: {e}")
            break

        # Extract thinking (text before the JSON block)
        action = parse_action(response)
        json_match = re.search(r'```(?:json)?\s*\n?', response)
        if json_match:
            thinking_text = response[:json_match.start()].strip()
        else:
            thinking_text = response.strip()

        if thinking_text:
            thinking_blocks.append(thinking_text)
            history.append({"type": "thinking", "text": thinking_text})

        if not action:
            retries_without_action += 1
            if retries_without_action >= 3:
                break
            continue

        retries_without_action = 0
        tool_name = action.get("tool", "")
        tool_input = action.get("input", {})

        if tool_name == "conclude":
            executor.conclusion = tool_input
            break

        if tool_name in ("run_sql", "get_schema", "list_tables"):
            result = executor.execute(tool_name, tool_input)
            history.append({
                "type": "tool_result",
                "tool": tool_name,
                "input": tool_input,
                "result": result,
            })
        else:
            history.append({
                "type": "thinking",
                "text": f"Unknown tool requested: {tool_name}",
            })

        if executor.conclusion:
            break

    return {
        "conclusion": executor.conclusion,
        "log": executor.log,
        "query_count": executor.query_count,
        "thinking": thinking_blocks,
    }


# ─── MCP formatting ─────────────────────────────────────────────────────────

def format_result_for_mcp(problem: str, result: dict) -> str:
    """Formats the investigation result into readable text for MCP."""
    lines = []
    lines.append("# Data Detective — Investigation result\n")
    lines.append(f"**Problem:** {problem}\n")
    lines.append(f"**Queries executed:** {result['query_count']}\n")

    if result["log"]:
        lines.append("**Investigation log:**")
        for entry in result["log"]:
            lines.append(f"  - {entry}")
        lines.append("")

    if result["thinking"]:
        lines.append("**Agent analysis:**")
        for thought in result["thinking"]:
            short = thought[:300] + "..." if len(thought) > 300 else thought
            lines.append(f"  {short}")
        lines.append("")

    conclusion = result.get("conclusion")
    if not conclusion:
        lines.append("Agent did not provide a final conclusion.")
        return "\n".join(lines)

    status = conclusion.get("status", "inconclusive")
    labels = {"found": "ROOT CAUSE FOUND", "inconclusive": "INCONCLUSIVE", "no_anomaly": "NO ANOMALY"}
    lines.append(f"## {labels.get(status, 'UNKNOWN')} — Conclusion\n")

    if conclusion.get("root_cause"):
        lines.append(f"**Root Cause:**\n{conclusion['root_cause']}\n")

    if conclusion.get("evidence"):
        lines.append("**Evidence:**")
        for e in conclusion["evidence"]:
            lines.append(f"  - {e}")
        lines.append("")

    if conclusion.get("investigated_hypotheses"):
        lines.append("**Investigated hypotheses:**")
        for h in conclusion["investigated_hypotheses"]:
            lines.append(f"  - {h}")
        lines.append("")

    if conclusion.get("recommendation"):
        lines.append(f"**Recommendation:**\n{conclusion['recommendation']}")

    return "\n".join(lines)


def investigate_and_capture(
    problem: str, available_platforms: list[str], connectors: dict
) -> str:
    """Runs the investigation and returns formatted text. For the MCP server."""
    result = run_investigation(problem, available_platforms, connectors)
    return format_result_for_mcp(problem, result)
