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
