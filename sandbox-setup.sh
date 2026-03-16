#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  sandbox-setup.sh — Setup script for Docker Sandbox mode
#
#  Runs inside the sandbox via: docker sandbox exec <name> /opt/sandbox-setup.sh
#  Replaces network-lock.sh's non-firewall logic (settings merge,
#  MCP config, agent/command merge).
#
#  Network isolation is handled by docker sandbox network proxy
#  on the host side — no iptables needed here.
#
#  Env vars are passed via -e flags from the walter script.
# ══════════════════════════════════════════════════════════════

set -euo pipefail

# ── Merge host settings with container hooks ──────────────────
HOST_SETTINGS="/tmp/host-settings.json"
CONTAINER_SETTINGS="$HOME/.claude/settings.json"

if [ -f "$HOST_SETTINGS" ] && [ -f "$CONTAINER_SETTINGS" ]; then
  echo "Merging host settings with container hooks..."
  MERGED=$(jq -s '.[0] * .[1] | .hooks = (.[0].hooks // {}) * (.[1].hooks // {})' \
    "$HOST_SETTINGS" "$CONTAINER_SETTINGS" 2>/dev/null) || true
  if [ -n "$MERGED" ]; then
    echo "$MERGED" > "$CONTAINER_SETTINGS"
    echo "  Settings merged (host preferences + container hooks)"
  fi
elif [ -f "$HOST_SETTINGS" ]; then
  cp "$HOST_SETTINGS" "$CONTAINER_SETTINGS"
  echo "  Host settings applied"
fi

# ── Merge host agents/commands/rules/skills ──────────────────
# These arrive via /tmp/walter-host-config/ (written by docker sandbox exec)

HOST_CONFIG="/tmp/walter-host-config"

if [ -d "$HOST_CONFIG/agents" ]; then
  mkdir -p "$HOME/.claude/agents"
  cp -r "$HOST_CONFIG/agents/"* "$HOME/.claude/agents/" 2>/dev/null || true
  echo "  Host agents merged"
fi

if [ -d "$HOST_CONFIG/commands" ]; then
  mkdir -p "$HOME/.claude/commands"
  cp -r "$HOST_CONFIG/commands/"* "$HOME/.claude/commands/" 2>/dev/null || true
  echo "  Host commands merged"
fi

if [ -d "$HOST_CONFIG/skills" ]; then
  mkdir -p "$HOME/.claude/skills"
  cp -r "$HOST_CONFIG/skills/"* "$HOME/.claude/skills/" 2>/dev/null || true
  echo "  Host skills merged"
fi

if [ -d "$HOST_CONFIG/rules" ]; then
  mkdir -p "$HOME/.claude/rules"
  cp -r "$HOST_CONFIG/rules/"* "$HOME/.claude/rules/" 2>/dev/null || true
  echo "  Host rules merged"
fi

if [ -f "$HOST_CONFIG/CLAUDE.md" ]; then
  cp "$HOST_CONFIG/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
  echo "  Host CLAUDE.md applied"
fi

# ── Ensure built-in files survive host merges ─────────────────
# Re-copy built-in agents/commands so repo-owned files override stale host copies.
BUILTIN_AGENTS_DIR="/opt/detective"
BUILTIN_GSD_AGENTS="/opt/gsd/agents"
BUILTIN_GSD_COMMANDS="/opt/gsd/commands"
BUILTIN_ROOT_COMMANDS="/opt/commands"

mkdir -p "$HOME/.claude/agents"
for f in "$BUILTIN_AGENTS_DIR"/*.md; do
  [ -f "$f" ] && cp "$f" "$HOME/.claude/agents/"
done
for f in "$BUILTIN_GSD_AGENTS"/*.md; do
  [ -f "$f" ] && cp "$f" "$HOME/.claude/agents/"
done

mkdir -p "$HOME/.claude/commands/gsd"
for f in "$BUILTIN_GSD_COMMANDS"/*.md; do
  [ -f "$f" ] && cp "$f" "$HOME/.claude/commands/gsd/"
done
for f in "$BUILTIN_ROOT_COMMANDS"/*.md; do
  [ -f "$f" ] && cp "$f" "$HOME/.claude/commands/"
done

echo "  Built-in agents + commands ensured"

# ── MCP servers ──────────────────────────────────────────────
MCP_CONFIG="/tmp/mcp-config.json"
MCP_JSON='{"mcpServers":{}}'

# ── MCP: Snowflake read-only server ──────────────────────────
if [ -n "${SNOWFLAKE_ACCOUNT:-}" ] && [ -f "${SNOWFLAKE_PRIVATE_KEY_PATH:-/opt/secrets/snowflake_key.pem}" ]; then
  MCP_JSON=$(echo "$MCP_JSON" | jq --arg acct "$SNOWFLAKE_ACCOUNT" \
    --arg user "$SNOWFLAKE_USER" \
    --arg key "${SNOWFLAKE_PRIVATE_KEY_PATH:-/opt/secrets/snowflake_key.pem}" \
    --arg wh "$SNOWFLAKE_WAREHOUSE" \
    --arg db "$SNOWFLAKE_DATABASE" \
    --arg role "$SNOWFLAKE_ROLE" \
    '.mcpServers["snowflake-readonly"] = {
      "command": "python3",
      "args": ["/opt/mcp/snowflake-readonly.py"],
      "env": {
        "SNOWFLAKE_ACCOUNT": $acct,
        "SNOWFLAKE_USER": $user,
        "SNOWFLAKE_PRIVATE_KEY_PATH": $key,
        "SNOWFLAKE_WAREHOUSE": $wh,
        "SNOWFLAKE_DATABASE": $db,
        "SNOWFLAKE_ROLE": $role
      }
    }')
  echo "MCP: snowflake-readonly (read-only)"
  echo "  Account:   $SNOWFLAKE_ACCOUNT"
  echo "  User:      $SNOWFLAKE_USER"
  echo "  Warehouse: $SNOWFLAKE_WAREHOUSE"
  echo "  Database:  $SNOWFLAKE_DATABASE"
  echo "  Role:      $SNOWFLAKE_ROLE"
  echo ""
fi

# ── MCP: BigQuery server ─────────────────────────────────────
if [ -n "${BQ_MCP_CONFIG_PATH:-}" ] && [ -f "$BQ_MCP_CONFIG_PATH" ]; then
  MCP_JSON=$(echo "$MCP_JSON" | jq \
    --arg config "$BQ_MCP_CONFIG_PATH" \
    '.mcpServers["bigquery"] = {
      "command": "python3",
      "args": ["/opt/mcp/bigquery/server.py"],
      "env": {
        "BQ_MCP_CONFIG_PATH": $config
      }
    }')
  echo "MCP: bigquery (read + write to configured dataset)"
  echo ""
fi

# ── MCP: Data Detective ─────────────────────────────────────
if [ -f "/opt/detective/mcp_server.py" ]; then
  DETECTIVE_ENV=$(jq -n \
    --arg model "${DETECTIVE_MODEL:-}" \
    --arg max_iter "${DETECTIVE_MAX_ITER:-}" \
    --arg bq_project "${BQ_PROJECT:-}" \
    --arg bq_creds "${BQ_CREDENTIALS_PATH:-}" \
    --arg sf_account "${SF_ACCOUNT:-}" \
    --arg sf_user "${SF_USER:-}" \
    --arg sf_password "${SF_PASSWORD:-}" \
    --arg sf_key_path "${SF_PRIVATE_KEY_PATH:-}" \
    --arg sf_warehouse "${SF_WAREHOUSE:-}" \
    --arg sf_database "${SF_DATABASE:-}" \
    --arg sf_schema "${SF_SCHEMA:-}" \
    --arg sf_role "${SF_ROLE:-}" \
    '{}
    + if $model != "" then {"DETECTIVE_MODEL": $model} else {} end
    + if $max_iter != "" then {"DETECTIVE_MAX_ITER": $max_iter} else {} end
    + if $bq_project != "" then {"BQ_PROJECT": $bq_project} else {} end
    + if $bq_creds != "" then {"BQ_CREDENTIALS_PATH": $bq_creds} else {} end
    + if $sf_account != "" then {"SF_ACCOUNT": $sf_account} else {} end
    + if $sf_user != "" then {"SF_USER": $sf_user} else {} end
    + if $sf_password != "" then {"SF_PASSWORD": $sf_password} else {} end
    + if $sf_key_path != "" then {"SF_PRIVATE_KEY_PATH": $sf_key_path} else {} end
    + if $sf_warehouse != "" then {"SF_WAREHOUSE": $sf_warehouse} else {} end
    + if $sf_database != "" then {"SF_DATABASE": $sf_database} else {} end
    + if $sf_schema != "" then {"SF_SCHEMA": $sf_schema} else {} end
    + if $sf_role != "" then {"SF_ROLE": $sf_role} else {} end')

  MCP_JSON=$(echo "$MCP_JSON" | jq --argjson env "$DETECTIVE_ENV" \
    '.mcpServers["data-detective"] = {
      "command": "python3",
      "args": ["/opt/detective/mcp_server.py"],
      "env": $env
    }')

  echo "MCP: data-detective (autonomous investigation)"
  [ -n "${BQ_PROJECT:-}" ] && echo "  BigQuery:  $BQ_PROJECT"
  [ -n "${SF_ACCOUNT:-}" ] && echo "  Snowflake: $SF_ACCOUNT"
  echo ""
fi

# ── MCP: Memory Tool ─────────────────────────────────────────
if [ -f "/opt/memory_tool/mcp_server.py" ]; then
  # Copy Python files to local filesystem for fast imports
  MEMORY_FAST="/tmp/memory_tool_fast"
  mkdir -p "$MEMORY_FAST"
  cp /opt/memory_tool/*.py "$MEMORY_FAST/" 2>/dev/null || true
  chmod 644 "$MEMORY_FAST/"*.py 2>/dev/null || true
  python3 -m compileall -q "$MEMORY_FAST/" 2>/dev/null || true

  MCP_JSON=$(echo "$MCP_JSON" | jq \
    '.mcpServers["memory-tool"] = {
      "command": "python3",
      "args": ["/tmp/memory_tool_fast/mcp_server.py"],
      "env": {
        "MEMORY_DB_DIR": "/opt/memory_tool/chromadb_data"
      }
    }')
  echo "MCP: memory-tool (cognitive memory)"
  echo ""
fi

# ── Write MCP config if any servers registered ───────────────
HAS_MCP=$(echo "$MCP_JSON" | jq '.mcpServers | length')
if [ "$HAS_MCP" -gt 0 ]; then
  echo "$MCP_JSON" > "$MCP_CONFIG"
  echo "MCP config written to $MCP_CONFIG ($HAS_MCP servers)"
fi

# ── Auth diagnostics ──────────────────────────────────────────
echo ""
echo "Auth check:"
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "  CLAUDE_CODE_OAUTH_TOKEN is set (${CLAUDE_CODE_OAUTH_TOKEN:0:4}...)"
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "  ANTHROPIC_API_KEY is set (${ANTHROPIC_API_KEY:0:10}...)"
else
  echo "  No auth token found in environment"
fi

echo ""
echo "Sandbox setup complete."
