#!/usr/bin/env python3
"""
Minimal smoke test for the BigQuery MCP server.

Requires real GCP credentials. Set BQ_MCP_TEST_CONFIG to a valid config JSON path.
Skips all tests if env var is not set.

Usage:
  BQ_MCP_TEST_CONFIG=/path/to/config.json python3 mcp/bigquery/test_smoke.py
"""

import os
import sys

# 1. Verify imports
print("Checking imports...", end=" ")
try:
    from mcp.server.fastmcp import FastMCP
    from google.cloud import bigquery
    print("OK")
except ImportError as e:
    print(f"FAILED: {e}")
    sys.exit(1)

# 2. Import server module
print("Importing server module...", end=" ")
sys.path.insert(0, os.path.dirname(__file__))
import server  # noqa: E402
print("OK")

# 3. Check for test config
config_path = os.environ.get("BQ_MCP_TEST_CONFIG")
if not config_path:
    print("\nBQ_MCP_TEST_CONFIG not set — skipping live tests.")
    print("SMOKE TEST PASSED (imports only)")
    sys.exit(0)

os.environ["BQ_MCP_CONFIG_PATH"] = config_path

# 4. Test list_projects
print("Testing list_projects()...", end=" ")
result = server.list_projects()
assert result and "error" not in result.lower(), f"Failed: {result}"
print("OK")

# 5. Test list_datasets with first project from config
import json
config = json.loads(open(config_path).read())
project_id = config.get("write_dataset", {}).get("project_id")
if project_id:
    print(f"Testing list_datasets({project_id})...", end=" ")
    result = server.list_datasets(project_id)
    assert result and "error" not in result.lower(), f"Failed: {result}"
    print("OK")
else:
    print("No write_dataset.project_id in config — skipping list_datasets test.")

print("\nSMOKE TEST PASSED")
