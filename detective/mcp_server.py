#!/usr/bin/env python3
"""
data-detective MCP server
==========================
Registers Data Detective as a tool in Claude Code.

Registration:
    claude mcp add data-detective python /path/to/data-detective/mcp_server.py

Usage in Claude Code:
    "why does user_id=12345 have revenue < 100 for yesterday"
    "investigate: more NULLs in the orders table since the 16th"
"""

import sys
import os
import json
import asyncio
import traceback
from pathlib import Path
from typing import Any

# Add the agent folder to path
sys.path.insert(0, str(Path(__file__).parent))

from dotenv import load_dotenv
load_dotenv(Path(__file__).parent / ".env")

import mcp.server.stdio
import mcp.types as types
from mcp.server import Server
from mcp.server.models import InitializationOptions

# ─── Server initialization ───────────────────────────────────────────────────

server = Server("data-detective")

# ─── Connector initialization ────────────────────────────────────────────────

def get_available_connectors() -> dict:
    """Attempts to connect to available platforms."""
    from connectors import BigQueryConnector, SnowflakeConnector

    connectors = {}

    # BigQuery
    if os.getenv("BQ_PROJECT"):
        try:
            conn = BigQueryConnector(
                project=os.environ["BQ_PROJECT"],
                credentials_path=os.getenv("BQ_CREDENTIALS_PATH"),
            )
            conn.test_connection()
            connectors["bigquery"] = conn
        except Exception as e:
            sys.stderr.write(f"[data-detective] BigQuery unavailable: {e}\n")

    # Snowflake
    if os.getenv("SF_ACCOUNT") and os.getenv("SF_USER"):
        try:
            conn = SnowflakeConnector(
                account=os.environ["SF_ACCOUNT"],
                user=os.environ["SF_USER"],
                password=os.getenv("SF_PASSWORD"),
                private_key_path=os.getenv("SF_PRIVATE_KEY_PATH"),
                warehouse=os.getenv("SF_WAREHOUSE", "COMPUTE_WH"),
                database=os.getenv("SF_DATABASE"),
                schema=os.getenv("SF_SCHEMA"),
                role=os.getenv("SF_ROLE"),
            )
            conn.test_connection()
            connectors["snowflake"] = conn
        except Exception as e:
            sys.stderr.write(f"[data-detective] Snowflake unavailable: {e}\n")

    return connectors


# ─── Tools ──────────────────────────────────────────────────────────────────

@server.list_tools()
async def list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="investigate_data_issue",
            description=(
                "Autonomously investigates data anomalies and issues in BigQuery and/or Snowflake. "
                "Forms hypotheses, iteratively runs SQL, finds root cause. "
                "Use when you need to find out: why a metric dropped, where NULLs came from, "
                "why data didn't reconcile, what broke in the pipeline."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "problem": {
                        "type": "string",
                        "description": (
                            "Description of the problem in natural language. Examples:\n"
                            "- 'why does user_id=12345 have revenue < 100 for yesterday'\n"
                            "- 'more NULLs than usual in the orders table since February 16th'\n"
                            "- 'DAU dropped 30% yesterday'\n"
                            "- 'pipeline completed successfully but data for 2026-02-19 was not loaded'"
                        )
                    },
                    "platform": {
                        "type": "string",
                        "enum": ["bigquery", "snowflake", "both"],
                        "description": "Where to search. Default: both (will try both)",
                        "default": "both"
                    },
                    "context": {
                        "type": "string",
                        "description": (
                            "Additional context: table names, schemas, business logic. "
                            "Optional, but speeds up the investigation."
                        )
                    }
                },
                "required": ["problem"]
            }
        )
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict[str, Any]) -> list[types.TextContent]:
    if name != "investigate_data_issue":
        raise ValueError(f"Unknown tool: {name}")

    problem = arguments["problem"]
    platform = arguments.get("platform", "both")
    context = arguments.get("context", "")

    # If context is provided — append it to the problem
    full_problem = problem
    if context:
        full_problem = f"{problem}\n\nAdditional context:\n{context}"

    # Initialize connectors
    all_connectors = get_available_connectors()

    if platform == "both":
        connectors = all_connectors
        available_platforms = list(all_connectors.keys())
    else:
        connectors = {platform: all_connectors[platform]} if platform in all_connectors else {}
        available_platforms = [platform] if connectors else []

    if not connectors:
        return [types.TextContent(
            type="text",
            text=f"❌ No available connectors for platform '{platform}'. Check the .env file."
        )]

    # Run investigation
    from detective_core import investigate_and_capture

    result = await asyncio.get_running_loop().run_in_executor(
        None,
        investigate_and_capture,
        full_problem,
        available_platforms,
        connectors
    )

    return [types.TextContent(type="text", text=result)]


# ─── Main ────────────────────────────────────────────────────────────────────

async def main():
    async with mcp.server.stdio.stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            InitializationOptions(
                server_name="data-detective",
                server_version="1.0.0",
                capabilities=server.get_capabilities(
                    notification_options=None,
                    experimental_capabilities={}
                ),
            ),
        )

if __name__ == "__main__":
    asyncio.run(main())
