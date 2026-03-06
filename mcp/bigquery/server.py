#!/usr/bin/env python3
"""
bigquery — MCP server for BigQuery access (read + restricted write).

Read-only tools:
  list_projects()                          — list accessible GCP projects
  list_datasets(project_id)                — list datasets in a project
  list_tables(project_id, dataset_id)      — list tables in a dataset
  get_table_schema(project_id, dataset_id, table_id) — column metadata

Dual-mode tool:
  run_query(sql)                           — SELECT/WITH = read-only; DML/DDL = write-restricted

Write-restricted tools (target must match configured write_dataset):
  create_table(project_id, dataset_id, table_id, schema_json)
  insert_rows(project_id, dataset_id, table_id, rows_json)
  create_or_replace_table_as(project_id, dataset_id, table_id, select_sql)
"""

import json
import os
import re
import sys
from pathlib import Path
from typing import Any

from google.cloud import bigquery
from google.oauth2 import service_account
from mcp.server.fastmcp import FastMCP

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from sql_utils import strip_sql_comments as _shared_strip, validate_identifier as _shared_validate, to_markdown_table as _shared_markdown

# ── Constants ────────────────────────────────────────────────

ROW_LIMIT = 1000

# ── Config helpers ───────────────────────────────────────────

_cached_config = None
_cached_client = None


def _load_config() -> dict:
    """Load JSON config from BQ_MCP_CONFIG_PATH (cached after first read)."""
    global _cached_config
    if _cached_config is not None:
        return _cached_config
    path = os.environ.get("BQ_MCP_CONFIG_PATH", "/opt/mcp/bigquery/config.json")
    try:
        _cached_config = json.loads(Path(path).read_text())
        return _cached_config
    except FileNotFoundError:
        raise RuntimeError(f"BigQuery MCP config not found: {path}")
    except json.JSONDecodeError as e:
        raise RuntimeError(f"BigQuery MCP config is malformed JSON: {path} — {e}")


def _get_client() -> bigquery.Client:
    """Build a BigQuery client based on auth_mode in config (cached after first call)."""
    global _cached_client
    if _cached_client is not None:
        return _cached_client
    config = _load_config()
    mode = config.get("auth_mode", "adc")

    if mode == "adc":
        _cached_client = bigquery.Client()
        return _cached_client

    if mode == "service_account":
        key_path = config.get("service_account_key_path", "")
        if not os.path.exists(key_path):
            fallback = "/opt/secrets/bq-sa-key.json"
            if os.path.exists(fallback):
                key_path = fallback
            else:
                raise FileNotFoundError(
                    f"Service account key not found at '{key_path}' or fallback '{fallback}'. "
                    "Mount the key file and set service_account_key_path in config."
                )
        creds = service_account.Credentials.from_service_account_file(
            key_path, scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        _cached_client = bigquery.Client(credentials=creds)
        return _cached_client

    raise ValueError(f"Unknown auth_mode: {mode}")


def _get_write_dataset() -> tuple[str, str]:
    """Return (project_id, dataset_id) for the configured write dataset."""
    config = _load_config()
    wd = config.get("write_dataset")
    if not wd or "project_id" not in wd or "dataset_id" not in wd:
        raise RuntimeError(
            "write_dataset.project_id and write_dataset.dataset_id must be set in config."
        )
    return wd["project_id"], wd["dataset_id"]


def _is_write_allowed(target_project: str, target_dataset: str) -> bool:
    """Check if the target project.dataset matches the configured write dataset."""
    allowed_project, allowed_dataset = _get_write_dataset()
    return target_project == allowed_project and target_dataset == allowed_dataset


# ── SQL helpers ──────────────────────────────────────────────

_strip_sql_comments = _shared_strip
_validate_identifier = _shared_validate


_WRITE_TARGET_RE = re.compile(
    r"""(?:INSERT\s+INTO|CREATE\s+(?:OR\s+REPLACE\s+)?TABLE|MERGE\s+INTO|UPDATE|DELETE\s+FROM)
        \s+`?([a-zA-Z0-9_-]+(?:\.[a-zA-Z0-9_-]+){1,2})`?""",
    re.IGNORECASE | re.VERBOSE,
)


def _parse_write_target(sql: str) -> tuple[str, str] | None:
    """Extract (project_id, dataset_id) from a write SQL statement.

    Returns None if no target can be parsed.
    Handles `project.dataset.table` and `dataset.table` forms.
    """
    m = _WRITE_TARGET_RE.search(sql)
    if not m:
        return None
    parts = m.group(1).replace("`", "").split(".")
    if len(parts) == 3:
        return parts[0], parts[1]
    if len(parts) == 2:
        # dataset.table — project unknown; use write_dataset project as default
        try:
            allowed_project, _ = _get_write_dataset()
            return allowed_project, parts[0]
        except RuntimeError:
            return None
    return None


_to_markdown_table = _shared_markdown


# ── MCP Server ───────────────────────────────────────────────

mcp = FastMCP(
    "bigquery",
    description="BigQuery access: full read + restricted write to configured dataset.",
)


@mcp.tool()
def list_projects() -> str:
    """List all GCP projects accessible to the current credentials."""
    try:
        client = _get_client()
        projects = list(client.list_projects())
        if not projects:
            return "_No projects found_"
        columns = ["project_id", "friendly_name"]
        rows = [[p.project_id, p.friendly_name or ""] for p in projects]
        return _to_markdown_table(columns, rows)
    except Exception as e:
        return f"**BigQuery error**: {e}"


@mcp.tool()
def list_datasets(project_id: str) -> str:
    """List all datasets in a GCP project.

    Args:
        project_id: The GCP project ID (e.g. 'my-gcp-project').
    """
    try:
        client = _get_client()
        datasets = list(client.list_datasets(project=project_id))
        if not datasets:
            return "_No datasets found_"
        columns = ["dataset_id", "full_dataset_id", "location"]
        rows = [
            [d.dataset_id, d.full_dataset_id, d.reference.dataset_id]
            for d in datasets
        ]
        return _to_markdown_table(columns, rows)
    except Exception as e:
        return f"**BigQuery error**: {e}"


@mcp.tool()
def list_tables(project_id: str, dataset_id: str) -> str:
    """List all tables in a BigQuery dataset.

    Args:
        project_id: The GCP project ID.
        dataset_id: The dataset ID.
    """
    try:
        client = _get_client()
        tables = list(client.list_tables(f"{project_id}.{dataset_id}"))
        if not tables:
            return "_No tables found_"
        columns = ["table_id", "table_type", "full_table_id"]
        rows = [[t.table_id, t.table_type, t.full_table_id] for t in tables]
        return _to_markdown_table(columns, rows)
    except Exception as e:
        return f"**BigQuery error**: {e}"


@mcp.tool()
def get_table_schema(project_id: str, dataset_id: str, table_id: str) -> str:
    """Get column schema for a BigQuery table.

    Args:
        project_id: The GCP project ID.
        dataset_id: The dataset ID.
        table_id: The table ID.
    """
    try:
        client = _get_client()
        table = client.get_table(f"{project_id}.{dataset_id}.{table_id}")
        if not table.schema:
            return "_No schema found_"
        columns = ["name", "field_type", "mode", "description"]
        rows = [
            [f.name, f.field_type, f.mode, f.description or ""]
            for f in table.schema
        ]
        return _to_markdown_table(columns, rows)
    except Exception as e:
        return f"**BigQuery error**: {e}"


@mcp.tool()
def run_query(sql: str) -> str:
    """Execute a SQL query against BigQuery.

    SELECT/WITH queries run as read-only. DML/DDL queries are restricted to the
    configured write dataset. Results are capped at 1000 rows.
    Use LIMIT clauses to avoid expensive full-table scans.

    Args:
        sql: The SQL query to execute.
    """
    try:
        cleaned = _strip_sql_comments(sql).strip()
        first_word = cleaned.lower().split()[0] if cleaned.split() else ""

        # Read-only path
        if first_word in ("select", "with"):
            client = _get_client()
            result = client.query(sql).result()
            columns = [f.name for f in result.schema]
            rows = []
            for i, row in enumerate(result):
                if i >= ROW_LIMIT:
                    break
                rows.append([row[c] for c in columns])
            table = _to_markdown_table(columns, rows)
            if result.total_rows and result.total_rows > ROW_LIMIT:
                table += f"\n\n_Showing first {ROW_LIMIT} rows. {result.total_rows} total rows._"
            return table

        # Write path — validate target dataset
        target = _parse_write_target(cleaned)
        if target is None:
            return (
                "**Error**: Could not determine target dataset from SQL. "
                "For write operations, use fully-qualified table names: `project.dataset.table`."
            )
        target_project, target_dataset = target
        if not _is_write_allowed(target_project, target_dataset):
            allowed_project, allowed_dataset = _get_write_dataset()
            return (
                f"**Error**: Write access denied. Target dataset "
                f"'{target_project}.{target_dataset}' is not the configured "
                f"write dataset '{allowed_project}.{allowed_dataset}'."
            )

        client = _get_client()
        result = client.query(sql).result()
        return "Query completed successfully."

    except Exception as e:
        return f"**BigQuery error**: {e}"


@mcp.tool()
def create_table(project_id: str, dataset_id: str, table_id: str, schema_json: str) -> str:
    """Create a new BigQuery table in the configured write dataset.

    Args:
        project_id: The GCP project ID.
        dataset_id: The dataset ID (must match configured write dataset).
        table_id: The new table name.
        schema_json: JSON array of column definitions, e.g.
                     [{"name": "id", "type": "INTEGER", "mode": "REQUIRED"}]
    """
    if not _is_write_allowed(project_id, dataset_id):
        allowed_project, allowed_dataset = _get_write_dataset()
        return (
            f"**Error**: Write access denied. Target '{project_id}.{dataset_id}' "
            f"is not the configured write dataset '{allowed_project}.{allowed_dataset}'."
        )
    try:
        schema_defs = json.loads(schema_json)
        schema = [
            bigquery.SchemaField(
                name=f["name"],
                field_type=f["type"],
                mode=f.get("mode", "NULLABLE"),
            )
            for f in schema_defs
        ]
        client = _get_client()
        table_ref = f"{project_id}.{dataset_id}.{table_id}"
        client.create_table(bigquery.Table(table_ref, schema=schema))
        return f"Table '{table_ref}' created successfully."
    except Exception as e:
        return f"**BigQuery error**: {e}"


@mcp.tool()
def insert_rows(project_id: str, dataset_id: str, table_id: str, rows_json: str) -> str:
    """Insert rows into a BigQuery table using streaming insert.

    Note: Rows inserted via streaming may take a few minutes to appear in query results
    due to BigQuery's streaming buffer.

    Args:
        project_id: The GCP project ID.
        dataset_id: The dataset ID (must match configured write dataset).
        table_id: The target table.
        rows_json: JSON array of row objects, e.g. [{"id": 1, "name": "Alice"}]
    """
    if not _is_write_allowed(project_id, dataset_id):
        allowed_project, allowed_dataset = _get_write_dataset()
        return (
            f"**Error**: Write access denied. Target '{project_id}.{dataset_id}' "
            f"is not the configured write dataset '{allowed_project}.{allowed_dataset}'."
        )
    try:
        rows = json.loads(rows_json)
        client = _get_client()
        table_ref = f"{project_id}.{dataset_id}.{table_id}"
        errors = client.insert_rows_json(table_ref, rows)
        if errors:
            return f"**Insert error**: {errors}"
        return f"Inserted {len(rows)} row(s) into '{table_ref}'."
    except Exception as e:
        return f"**BigQuery error**: {e}"


@mcp.tool()
def create_or_replace_table_as(
    project_id: str, dataset_id: str, table_id: str, select_sql: str
) -> str:
    """Create or replace a BigQuery table from a SELECT query (CTAS).

    Args:
        project_id: The GCP project ID.
        dataset_id: The dataset ID (must match configured write dataset).
        table_id: The target table name.
        select_sql: The SELECT query whose results will populate the table.
    """
    if not _is_write_allowed(project_id, dataset_id):
        allowed_project, allowed_dataset = _get_write_dataset()
        return (
            f"**Error**: Write access denied. Target '{project_id}.{dataset_id}' "
            f"is not the configured write dataset '{allowed_project}.{allowed_dataset}'."
        )
    if not all(_validate_identifier(n) for n in [project_id, dataset_id, table_id]):
        return "**Error**: Invalid characters in project/dataset/table identifiers."
    try:
        client = _get_client()
        sql = f"CREATE OR REPLACE TABLE `{project_id}.{dataset_id}.{table_id}` AS {select_sql}"
        client.query(sql).result()
        return f"Table '{project_id}.{dataset_id}.{table_id}' created/replaced successfully."
    except Exception as e:
        return f"**BigQuery error**: {e}"


if __name__ == "__main__":
    mcp.run(transport="stdio")
