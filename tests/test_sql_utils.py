"""Tests for mcp/sql_utils.py — SQL safety guard."""

import importlib.util
import pathlib

import pytest

# mcp/ is not a package (no __init__.py), load directly
_spec = importlib.util.spec_from_file_location(
    "sql_utils",
    pathlib.Path(__file__).parent.parent / "mcp" / "sql_utils.py",
)
sql_utils = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sql_utils)

check_sql_safety = sql_utils.check_sql_safety
strip_sql_comments = sql_utils.strip_sql_comments


# ---------------------------------------------------------------------------
# check_sql_safety: ALLOW cases (returns None)
# ---------------------------------------------------------------------------

ALLOW_CASES = [
    ("bare SELECT", "SELECT 1"),
    ("SELECT with table", "SELECT col FROM t"),
    ("WITH CTE", "WITH cte AS (SELECT 1) SELECT * FROM cte"),
    ("SELECT with line comment", "-- comment\nSELECT 1"),
    ("SELECT with block comment", "/* comment */ SELECT 1"),
    ("SELECT with trailing semicolon only", "SELECT 1;"),  # single statement
    ("SHOW TABLES", "SHOW TABLES"),
    ("DESCRIBE table", "DESCRIBE t"),
    ("DESC synonym", "DESC t"),
    ("EXPLAIN SELECT", "EXPLAIN SELECT 1"),
]

@pytest.mark.parametrize("label,sql", ALLOW_CASES)
def test_allow(label, sql):
    result = check_sql_safety(sql)
    assert result is None, f"[{label}] expected ALLOW but got: {result!r}"


# ---------------------------------------------------------------------------
# check_sql_safety: DENY cases (returns non-None error string)
# ---------------------------------------------------------------------------

DENY_CASES = [
    ("INSERT", "INSERT INTO t VALUES (1)"),
    ("UPDATE", "UPDATE t SET x=1"),
    ("DELETE", "DELETE FROM t"),
    ("DROP", "DROP TABLE t"),
    ("CREATE", "CREATE TABLE t (x INT)"),
    ("TRUNCATE", "TRUNCATE t"),
    ("ALTER", "ALTER TABLE t ADD COLUMN x INT"),
    ("MERGE", "MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN UPDATE SET t.x = s.x"),
    ("GRANT", "GRANT SELECT ON t TO u"),
    ("REVOKE", "REVOKE SELECT ON t FROM u"),
    ("multi-statement", "SELECT 1; DELETE FROM t"),
]

@pytest.mark.parametrize("label,sql", DENY_CASES)
def test_deny(label, sql):
    result = check_sql_safety(sql)
    assert result is not None, f"[{label}] expected DENY but got None (allowed)"
    assert isinstance(result, str), f"[{label}] error result should be a string"


# ---------------------------------------------------------------------------
# strip_sql_comments
# ---------------------------------------------------------------------------

def test_strip_line_comment():
    assert strip_sql_comments("-- comment\nSELECT 1").strip() == "SELECT 1"


def test_strip_block_comment():
    assert strip_sql_comments("/* comment */ SELECT 1").strip() == "SELECT 1"


def test_strip_double_slash_comment():
    assert strip_sql_comments("// comment\nSELECT 1").strip() == "SELECT 1"
