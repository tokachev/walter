"""
sql_utils.py — shared utilities for MCP servers (SQL formatting, validation).
"""

import re
from typing import Any


def strip_sql_comments(sql: str) -> str:
    """Remove --, // line comments and /* block comments */."""
    sql = re.sub(r"--[^\n]*", "", sql)
    sql = re.sub(r"//[^\n]*", "", sql)
    sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.DOTALL)
    return sql


def validate_identifier(name: str) -> bool:
    """Check that a name is a safe SQL identifier (alphanumeric, underscores, hyphens)."""
    return bool(re.match(r'^[a-zA-Z0-9_\-]+$', name))


def check_sql_safety(sql: str) -> str | None:
    """Check SQL for destructive operations (DROP, TRUNCATE, DELETE without WHERE).

    Returns None if safe, or an error message if blocked.
    """
    cleaned = strip_sql_comments(sql).strip()
    if not cleaned:
        return None

    normalized = " ".join(cleaned.lower().split())

    # Block multi-statement queries (e.g. SELECT 1; DELETE FROM t)
    segments = [s for s in cleaned.split(";") if s.strip()]
    if len(segments) > 1:
        return "SQL guardrail: multi-statement queries are blocked"

    # Allowlist: read-only query types per spec (SELECT/WITH/SHOW/DESCRIBE/DESC/EXPLAIN)
    first_keyword = normalized.split()[0] if normalized.split() else ""
    if first_keyword not in ("select", "with", "show", "describe", "desc", "explain"):
        return (
            f"SQL guardrail: only SELECT/WITH/SHOW/DESCRIBE/EXPLAIN queries are allowed. "
            f"Got: {first_keyword.upper()}"
        )

    # Block subquery-based writes: SELECT * FROM (DELETE ...), etc.
    write_verbs = r"\b(insert\s+into|update\s+\S+\s+set|delete\s+from|merge\s+into|drop\s|truncate\s|alter\s|create\s|grant\s|revoke\s)"
    if re.search(write_verbs, normalized):
        return "SQL guardrail: write operations inside SELECT are blocked"

    return None


def to_markdown_table(columns: list[str], rows: list[Any]) -> str:
    """Format query results as a markdown table."""
    if not rows:
        return "_No results_"

    col_names = [str(c) for c in columns]
    str_rows = [[str(v) for v in row] for row in rows]

    widths = [len(c) for c in col_names]
    for row in str_rows:
        for i, val in enumerate(row):
            widths[i] = max(widths[i], len(val))

    def fmt_row(vals):
        return "| " + " | ".join(v.ljust(w) for v, w in zip(vals, widths)) + " |"

    header = fmt_row(col_names)
    sep = "| " + " | ".join("-" * w for w in widths) + " |"
    body = "\n".join(fmt_row(r) for r in str_rows)
    return f"{header}\n{sep}\n{body}"
