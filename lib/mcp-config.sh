# lib/mcp-config.sh — MCP server registration logic (sourced, not executed)
#
# Globals set after mcp_generate_config returns:
#   MCP_ARGS    — array: empty or ("--mcp-config" "/tmp/mcp-config.json")
#   MCP_CONFIG  — path to generated config (/tmp/mcp-config.json)
#   ALL_DOMAINS — MAY BE MUTATED (MCP-specific domains appended)
#
# Requires firewall_allow_domain from lib/firewall.sh to be loaded first.

mcp_generate_config() {
  declare -ga MCP_ARGS
  MCP_ARGS=()
  MCP_CONFIG="/tmp/mcp-config.json"
  MCP_JSON='{"mcpServers":{}}'

  # ── MCP: Snowflake read-only server ────────────────────────────
  if [ -n "$SNOWFLAKE_ACCOUNT" ] && [ -f "${SNOWFLAKE_PRIVATE_KEY_PATH:-/opt/secrets/snowflake_key.pem}" ]; then
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
    echo "🔌 MCP: snowflake-readonly (read-only)"
    echo "  Account:   $SNOWFLAKE_ACCOUNT"
    echo "  User:      $SNOWFLAKE_USER"
    echo "  Warehouse: $SNOWFLAKE_WAREHOUSE"
    echo "  Database:  $SNOWFLAKE_DATABASE"
    echo "  Role:      $SNOWFLAKE_ROLE"
    echo ""
  fi

  # ── MCP: BigQuery server ────────────────────────────────────────
  if [ -n "$BQ_MCP_CONFIG_PATH" ] && [ -f "$BQ_MCP_CONFIG_PATH" ]; then
    MCP_JSON=$(echo "$MCP_JSON" | jq \
      --arg config "$BQ_MCP_CONFIG_PATH" \
      '.mcpServers["bigquery"] = {
        "command": "python3",
        "args": ["/opt/mcp/bigquery/server.py"],
        "env": {
          "BQ_MCP_CONFIG_PATH": $config
        }
      }')
    echo "🔌 MCP: bigquery (read + write to configured dataset)"

    # Add BigQuery API domains to firewall allowlist (if not already added by detective)
    BQ_DOMAINS="bigquery.googleapis.com,storage.googleapis.com,oauth2.googleapis.com"
    ALL_DOMAINS="$ALL_DOMAINS,$BQ_DOMAINS"
    firewall_allow_domain "$BQ_DOMAINS"
    echo "  ✓ BigQuery API domains added to firewall allowlist"
    echo ""
  fi

  # ── MCP: Data Detective ─────────────────────────────────────────
  # Detective uses claude CLI for LLM calls (inherits OAuth) — no API key needed.
  # Always register if detective files exist; connectors checked at runtime.
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

    echo "🔌 MCP: data-detective (autonomous investigation)"
    [ -n "$BQ_PROJECT" ] && echo "  BigQuery:  $BQ_PROJECT"
    [ -n "$SF_ACCOUNT" ] && echo "  Snowflake: $SF_ACCOUNT"
    echo ""

    # Add Snowflake domain to firewall allowlist if SF is configured
    if [ -n "$SF_ACCOUNT" ]; then
      SF_DOMAIN="${SF_ACCOUNT}.snowflakecomputing.com"
      ALL_DOMAINS="$ALL_DOMAINS,$SF_DOMAIN"
      firewall_allow_domain "$SF_DOMAIN"
      echo "  ✓ Snowflake domain added to firewall allowlist"
    fi

    # Add BigQuery API domains to firewall allowlist if BQ is configured
    if [ -n "$BQ_PROJECT" ]; then
      BQ_DOMAINS="bigquery.googleapis.com,storage.googleapis.com"
      ALL_DOMAINS="$ALL_DOMAINS,$BQ_DOMAINS"
      firewall_allow_domain "$BQ_DOMAINS"
      echo "  ✓ BigQuery API domains added to firewall allowlist"
    fi
  fi

  # ── Write MCP config if any servers registered ─────────────────
  HAS_MCP=$(echo "$MCP_JSON" | jq '.mcpServers | length')
  if [ "$HAS_MCP" -gt 0 ]; then
    echo "$MCP_JSON" > "$MCP_CONFIG"
    MCP_ARGS=(--mcp-config "$MCP_CONFIG")
  fi
}
