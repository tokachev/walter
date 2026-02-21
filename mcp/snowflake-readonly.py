#!/usr/bin/env python3
"""
snowflake-readonly — MCP server for read-only Snowflake access.

Tools:
  query(sql)                  — run a read-only SQL statement
  list_schemas()              — list schemas in the current database
  list_tables(schema)         — list tables in a schema
  describe_table(schema, table) — column metadata for a table

SQL validation: only SELECT, SHOW, DESCRIBE, WITH, EXPLAIN are allowed.
"""

import os
import re

import snowflake.connector
from mcp.server.fastmcp import FastMCP

# ── Config from env ──────────────────────────────────────────

SNOWFLAKE_ACCOUNT = os.environ.get("SNOWFLAKE_ACCOUNT", "")
SNOWFLAKE_USER = os.environ.get("SNOWFLAKE_USER", "")
SNOWFLAKE_PRIVATE_KEY_PATH = os.environ.get(
    "SNOWFLAKE_PRIVATE_KEY_PATH", "/opt/secrets/snowflake_key.pem"
)
SNOWFLAKE_WAREHOUSE = os.environ.get("SNOWFLAKE_WAREHOUSE", "")
SNOWFLAKE_DATABASE = os.environ.get("SNOWFLAKE_DATABASE", "")
SNOWFLAKE_ROLE = os.environ.get("SNOWFLAKE_ROLE", "")

ROW_LIMIT = 100

ALLOWED_PREFIXES = ("select", "show", "describe", "with", "explain")
DANGEROUS_KEYWORDS = (
    "insert", "update", "delete", "create", "drop", "alter",
    "merge", "truncate", "grant", "revoke", "copy", "put",
    "get", "remove", "call", "exec",
)

# ── SQL validation ───────────────────────────────────────────

def _strip_sql_comments(sql: str) -> str:
    """Remove -- line comments and /* block comments */."""
    sql = re.sub(r"--[^\n]*", "", sql)
    sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.DOTALL)
    return sql


def validate_sql(sql: str) -> str | None:
    """Return None if valid, or an error message if rejected."""
    cleaned = _strip_sql_comments(sql).strip().lower()
    if not cleaned:
        return "Empty query"

    # Reject multiple statements (semicolons followed by more SQL)
    parts = [p.strip() for p in cleaned.split(";") if p.strip()]
    if len(parts) > 1:
        return "Multiple statements are not allowed"

    first = parts[0]

    if first.startswith("with"):
        # CTE — allowed only if it doesn't contain dangerous DML/DDL
        for kw in DANGEROUS_KEYWORDS:
            # Match keyword as whole word so e.g. "description" doesn't trip "create"
            if re.search(rf"\b{kw}\b", first):
                return f"Rejected: WITH ... {kw.upper()} is not allowed"
        return None

    if first.startswith(ALLOWED_PREFIXES):
        return None

    first_word = first.split()[0] if first.split() else first
    return f"Rejected: {first_word.upper()} statements are not allowed (read-only)"


# ── Snowflake connection ─────────────────────────────────────

def _load_private_key():
    """Load RSA private key from PEM file for key-pair auth."""
    from cryptography.hazmat.primitives import serialization
    with open(SNOWFLAKE_PRIVATE_KEY_PATH, "rb") as f:
        p_key = serialization.load_pem_private_key(f.read(), password=None)
    return p_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def _get_connection():
    return snowflake.connector.connect(
        account=SNOWFLAKE_ACCOUNT,
        user=SNOWFLAKE_USER,
        private_key=_load_private_key(),
        warehouse=SNOWFLAKE_WAREHOUSE,
        database=SNOWFLAKE_DATABASE,
        role=SNOWFLAKE_ROLE,
    )


# ── Markdown formatter ───────────────────────────────────────

def _to_markdown_table(columns: list[str], rows: list[tuple]) -> str:
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


# ── MCP Server ───────────────────────────────────────────────

mcp = FastMCP(
    "snowflake-readonly",
    description="Read-only Snowflake access. Only SELECT/SHOW/DESCRIBE/EXPLAIN allowed.",
)


@mcp.tool()
def query(sql: str) -> str:
    """Execute a read-only SQL query against Snowflake.

    Only SELECT, SHOW, DESCRIBE, WITH (CTE), and EXPLAIN are permitted.
    Results are limited to 100 rows and returned as a markdown table.
    """
    error = validate_sql(sql)
    if error:
        return f"**Error**: {error}"

    conn = _get_connection()
    try:
        cur = conn.cursor()
        try:
            cur.execute(sql)
            columns = [desc[0] for desc in cur.description]
            rows = cur.fetchmany(ROW_LIMIT)
            has_more = cur.fetchone() is not None
        finally:
            cur.close()
    except Exception as e:
        return f"**Snowflake error**: {e}"
    finally:
        conn.close()

    table = _to_markdown_table(columns, rows)
    note = f"\n\n_Showing first {ROW_LIMIT} rows. More rows exist._" if has_more else ""
    return table + note


@mcp.tool()
def list_schemas() -> str:
    """List all schemas in the current Snowflake database."""
    conn = _get_connection()
    try:
        cur = conn.cursor()
        try:
            cur.execute("SHOW SCHEMAS")
            columns = [desc[0] for desc in cur.description]
            rows = cur.fetchall()
        finally:
            cur.close()
    except Exception as e:
        return f"**Snowflake error**: {e}"
    finally:
        conn.close()

    return _to_markdown_table(columns, rows)


@mcp.tool()
def list_tables(schema: str) -> str:
    """List all tables in a Snowflake schema.

    Args:
        schema: The schema name (e.g. 'PUBLIC', 'RAW').
    """
    error = validate_sql(f"SHOW TABLES IN SCHEMA {schema}")
    if error:
        return f"**Error**: {error}"

    conn = _get_connection()
    try:
        cur = conn.cursor()
        try:
            cur.execute(f"SHOW TABLES IN SCHEMA {conn.database}.{schema}")
            columns = [desc[0] for desc in cur.description]
            rows = cur.fetchall()
        finally:
            cur.close()
    except Exception as e:
        return f"**Snowflake error**: {e}"
    finally:
        conn.close()

    return _to_markdown_table(columns, rows)


@mcp.tool()
def describe_table(schema: str, table: str) -> str:
    """Describe columns in a Snowflake table.

    Args:
        schema: The schema name (e.g. 'PUBLIC').
        table: The table name (e.g. 'EVENTS').
    """
    error = validate_sql(f"DESCRIBE TABLE {schema}.{table}")
    if error:
        return f"**Error**: {error}"

    conn = _get_connection()
    try:
        cur = conn.cursor()
        try:
            cur.execute(f"DESCRIBE TABLE {conn.database}.{schema}.{table}")
            columns = [desc[0] for desc in cur.description]
            rows = cur.fetchall()
        finally:
            cur.close()
    except Exception as e:
        return f"**Snowflake error**: {e}"
    finally:
        conn.close()

    return _to_markdown_table(columns, rows)


if __name__ == "__main__":
    mcp.run(transport="stdio")
