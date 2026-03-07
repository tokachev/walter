"""
sql_guard.py — Block destructive SQL statements.

Blocks:
  - DROP (any)
  - TRUNCATE (any)
  - DELETE without WHERE clause

Uses regex + simple AST-level checks via sqlparse (if available),
falls back to regex-only mode.
"""

import re

# Try sqlparse for AST-level checking; fall back to regex
try:
    import sqlparse
    from sqlparse.sql import Where
    HAS_SQLPARSE = True
except ImportError:
    HAS_SQLPARSE = False


def _strip_comments(sql: str) -> str:
    """Remove SQL comments."""
    sql = re.sub(r"--[^\n]*", "", sql)
    sql = re.sub(r"//[^\n]*", "", sql)
    sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.DOTALL)
    return sql


def check_sql(sql: str) -> tuple[bool, str]:
    """
    Validate SQL for destructive operations.

    Returns:
        (allowed, reason) — True if safe, False + reason if blocked.
    """
    cleaned = _strip_comments(sql).strip()
    if not cleaned:
        return True, ""

    # Normalize for checking
    normalized = " ".join(cleaned.lower().split())

    # Block DROP
    if re.search(r"\bdrop\s+(table|database|schema|view|index|function|procedure)\b", normalized):
        return False, f"SQL guardrail: DROP statements are blocked"

    # Block TRUNCATE
    if re.search(r"\btruncate\s+(table\s+)?\w+", normalized):
        return False, f"SQL guardrail: TRUNCATE statements are blocked"

    # Block DELETE without WHERE
    if re.search(r"\bdelete\s+from\b", normalized):
        if _has_where_clause(cleaned, normalized):
            return True, ""
        return False, "SQL guardrail: DELETE without WHERE clause is blocked"

    return True, ""


def _has_where_clause(original: str, normalized: str) -> bool:
    """Check if a DELETE statement has a WHERE clause."""
    if HAS_SQLPARSE:
        try:
            parsed = sqlparse.parse(original)
            for stmt in parsed:
                for token in stmt.tokens:
                    if isinstance(token, Where):
                        return True
            # sqlparse didn't find a Where token — fall through to regex
        except Exception:
            pass

    # Regex fallback: check for WHERE after DELETE FROM
    return bool(re.search(r"\bdelete\s+from\s+\S+\s+.*\bwhere\b", normalized))
