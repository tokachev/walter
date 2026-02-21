#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  network-lock.sh — domain-based firewall for Docker container
#
#  Fixes applied:
#    #1: IPv6 fully blocked via ip6tables (DROP all)
#    #2: Domain-based filtering via DNS interception, not just IP
#        Resolves IPs at start + refreshes in background
#    #3: All nameservers from resolv.conf allowed
# ══════════════════════════════════════════════════════════════

set -e

# ── Parse allowlist ───────────────────────────────────────────
EXTRA_DOMAINS=""
if [ "$1" = "--allowlist" ]; then
  EXTRA_DOMAINS="$2"
  shift 2
fi

REQUIRED_DOMAINS="api.anthropic.com,console.anthropic.com,claude.ai"
ALL_DOMAINS="$REQUIRED_DOMAINS"
[ -n "$EXTRA_DOMAINS" ] && ALL_DOMAINS="$REQUIRED_DOMAINS,$EXTRA_DOMAINS"

# ══════════════════════════════════════════════════════════════
#  FIX #1: Block IPv6 entirely
# ══════════════════════════════════════════════════════════════

echo "🔒 Network lock: configuring firewall..."

ip6tables -F OUTPUT 2>/dev/null || true
ip6tables -F INPUT 2>/dev/null || true
ip6tables -P OUTPUT DROP 2>/dev/null || true
ip6tables -P INPUT DROP 2>/dev/null || true
ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
echo "  ✓ IPv6: fully blocked"

# ══════════════════════════════════════════════════════════════
#  FIX #3: Allow ALL nameservers from resolv.conf
# ══════════════════════════════════════════════════════════════

DNS_SERVERS=$(grep nameserver /etc/resolv.conf | awk '{print $2}')
if [ -z "$DNS_SERVERS" ]; then
  echo "  ⚠ No DNS servers found in /etc/resolv.conf"
  DNS_SERVERS="127.0.0.11 8.8.8.8"
  echo "  Using fallback: $DNS_SERVERS"
fi

# ══════════════════════════════════════════════════════════════
#  FIX #2: Resolve domains to IPs + background refresh
# ══════════════════════════════════════════════════════════════

ALLOWED_IPS_FILE="/tmp/.walter-allowed-ips"
: > "$ALLOWED_IPS_FILE"

resolve_domains() {
  local domains="$1"
  local ips=""
  IFS=',' read -ra DARR <<< "$domains"
  for domain in "${DARR[@]}"; do
    domain=$(echo "$domain" | xargs)
    for dns in $DNS_SERVERS; do
      NEW_IPS=$(dig +short @"$dns" "$domain" 2>/dev/null | grep -E '^[0-9]+\.' || true)
      [ -n "$NEW_IPS" ] && ips="$ips $NEW_IPS" && break
    done
  done
  echo "$ips" | tr ' ' '\n' | sort -u | grep -v '^$'
}

echo "  Resolving allowed domains..."
INITIAL_IPS=$(resolve_domains "$ALL_DOMAINS")

if [ -z "$INITIAL_IPS" ]; then
  echo "  ⚠ WARNING: Could not resolve any domains."
  echo "  Claude Code will NOT work."
  if [ -t 0 ]; then
    read -p "  Continue anyway? [y/N] " -n 1 -r; echo ""
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
  else
    exit 1
  fi
fi

echo "$INITIAL_IPS" > "$ALLOWED_IPS_FILE"

for ip in $INITIAL_IPS; do
  IFS=',' read -ra DARR <<< "$ALL_DOMAINS"
  for domain in "${DARR[@]}"; do
    domain=$(echo "$domain" | xargs)
    if dig +short "$domain" 2>/dev/null | grep -q "$ip"; then
      echo "  ✓ $domain → $ip"
      break
    fi
  done
done

# ── Background IP refresher ──────────────────────────────────
(
  while true; do
    sleep 300
    NEW_IPS=$(resolve_domains "$ALL_DOMAINS")
    if [ -n "$NEW_IPS" ]; then
      CURRENT=$(cat "$ALLOWED_IPS_FILE" 2>/dev/null)
      for ip in $NEW_IPS; do
        if ! echo "$CURRENT" | grep -q "^${ip}$"; then
          iptables -I OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT 2>/dev/null
          echo "$ip" >> "$ALLOWED_IPS_FILE"
        fi
      done
    fi
  done
) &
REFRESH_PID=$!

# ══════════════════════════════════════════════════════════════
#  Apply IPv4 iptables rules
# ══════════════════════════════════════════════════════════════

iptables -F OUTPUT 2>/dev/null || true
iptables -F INPUT 2>/dev/null || true

# Loopback
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT

# Established
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow DNS servers
for dns in $DNS_SERVERS; do
  iptables -A OUTPUT -p udp -d "$dns" --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp -d "$dns" --dport 53 -j ACCEPT
  echo "  ✓ DNS allowed → $dns"
done

# HTTPS to resolved IPs
for ip in $INITIAL_IPS; do
  iptables -A OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT
done

# DROP everything else
iptables -A OUTPUT -j LOG --log-prefix "WALTER-BLOCKED: " --log-level 4 2>/dev/null || true
iptables -A OUTPUT -j DROP
iptables -A INPUT -j DROP

echo ""
echo "🔒 Network lock ACTIVE:"
echo "  ✅ Allowed: ${ALL_DOMAINS//,/, } (HTTPS only)"
echo "  ✅ Allowed: DNS ($(echo $DNS_SERVERS | tr '\n' ', ' | sed 's/,$//'))"
echo "  ✅ Allowed: localhost"
echo "  🚫 Blocked: everything else (IPv4 DROP + IPv6 DROP)"
echo "  🔄 IP refresh: every 5 min (PID $REFRESH_PID)"
echo ""

# ── Connectivity test ─────────────────────────────────────────
echo "🧪 Testing..."

HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" --connect-timeout 5 "https://api.anthropic.com/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" != "000" ]; then
  echo "  ✓ api.anthropic.com — reachable (HTTP $HTTP_CODE)"
else
  echo "  ⚠ api.anthropic.com — FAILED"
fi

HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" --connect-timeout 3 "https://oauth2.googleapis.com/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "000" ]; then
  echo "  ✓ googleapis.com — blocked"
else
  echo "  🚨 googleapis.com — REACHABLE (FIREWALL LEAK!)"
fi

echo ""

# ── Auth diagnostics ──────────────────────────────────────────
echo "🔑 Auth check:"
if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
  echo "  ✓ CLAUDE_CODE_OAUTH_TOKEN is set (${CLAUDE_CODE_OAUTH_TOKEN:0:15}...)"
elif [ -n "$ANTHROPIC_API_KEY" ]; then
  echo "  ✓ ANTHROPIC_API_KEY is set (${ANTHROPIC_API_KEY:0:10}...)"
else
  echo "  ⚠ No auth token found in environment!"
fi
echo ""

# ── Merge host settings with container hooks ──────────────────
HOST_SETTINGS="/tmp/host-settings.json"
CONTAINER_SETTINGS="$HOME/.claude/settings.json"

if [ -f "$HOST_SETTINGS" ] && [ -f "$CONTAINER_SETTINGS" ]; then
  echo "⚙️  Merging host settings with container hooks..."
  MERGED=$(jq -s '.[0] * .[1] | .hooks = (.[0].hooks // {}) * (.[1].hooks // {})' \
    "$HOST_SETTINGS" "$CONTAINER_SETTINGS" 2>/dev/null) || true
  if [ -n "$MERGED" ]; then
    echo "$MERGED" > "$CONTAINER_SETTINGS"
    echo "  ✓ Settings merged (host preferences + container hooks)"
  fi
elif [ -f "$HOST_SETTINGS" ]; then
  cp "$HOST_SETTINGS" "$CONTAINER_SETTINGS"
  echo "  ✓ Host settings applied"
fi

# ── MCP servers ──────────────────────────────────────────────
MCP_ARGS=()
MCP_CONFIG="/tmp/mcp-config.json"
MCP_JSON='{"mcpServers":{}}'

# ── MCP: Snowflake read-only server ──────────────────────────
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

# ── MCP: Data Detective ─────────────────────────────────────
if [ -n "$ANTHROPIC_API_KEY" ] || [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
  DETECTIVE_ENV=$(jq -n --arg api_key "${ANTHROPIC_API_KEY:-}" \
    --arg oauth_token "${CLAUDE_CODE_OAUTH_TOKEN:-}" \
    --arg model "${DETECTIVE_MODEL:-}" \
    --arg max_iter "${DETECTIVE_MAX_ITER:-}" \
    --arg max_tokens "${DETECTIVE_MAX_TOKENS:-}" \
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
    + if $api_key != "" then {"ANTHROPIC_API_KEY": $api_key} else {} end
    + if $oauth_token != "" then {"CLAUDE_CODE_OAUTH_TOKEN": $oauth_token} else {} end
    + if $model != "" then {"DETECTIVE_MODEL": $model} else {} end
    + if $max_iter != "" then {"DETECTIVE_MAX_ITER": $max_iter} else {} end
    + if $max_tokens != "" then {"DETECTIVE_MAX_TOKENS": $max_tokens} else {} end
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

  # Add BigQuery API domains to firewall allowlist if BQ is configured
  if [ -n "$BQ_PROJECT" ]; then
    BQ_DOMAINS="bigquery.googleapis.com,storage.googleapis.com"
    ALL_DOMAINS="$ALL_DOMAINS,$BQ_DOMAINS"
    echo "  ✓ BigQuery API domains added to firewall allowlist"

    # Resolve and allow BigQuery IPs
    BQ_IPS=$(resolve_domains "$BQ_DOMAINS")
    for ip in $BQ_IPS; do
      iptables -I OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT 2>/dev/null || true
      echo "$ip" >> "$ALLOWED_IPS_FILE"
    done
  fi
fi

# ── MCP: Memory Tool ─────────────────────────────────────────
if [ -f "/opt/memory_tool/mcp_server.py" ]; then
  MCP_JSON=$(echo "$MCP_JSON" | jq \
    '.mcpServers["memory-tool"] = {
      "command": "python3",
      "args": ["/opt/memory_tool/mcp_server.py"],
      "env": {
        "MEMORY_DB_DIR": "/opt/memory_tool/chromadb_data"
      }
    }')
  echo "🔌 MCP: memory-tool (cognitive memory)"
  echo ""
fi

# ── Write MCP config if any servers registered ───────────────
HAS_MCP=$(echo "$MCP_JSON" | jq '.mcpServers | length')
if [ "$HAS_MCP" -gt 0 ]; then
  echo "$MCP_JSON" > "$MCP_CONFIG"
  MCP_ARGS=(--mcp-config "$MCP_CONFIG")
fi

# ── Ensure built-in agents survive host agents mount ─────────
# If host mounted ~/.claude/agents (read-only), it shadows the Dockerfile
# agents. Copy built-in agents into a writable merged dir and point HOME there.
AGENTS_DIR="$HOME/.claude/agents"
BUILTIN_AGENTS_DIR="/opt/detective"
NEEDS_MERGE=false

if [ -d "$AGENTS_DIR" ] && [ -d "$BUILTIN_AGENTS_DIR" ]; then
  for f in "$BUILTIN_AGENTS_DIR"/*.md; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    if [ ! -f "$AGENTS_DIR/$fname" ]; then
      NEEDS_MERGE=true
      break
    fi
  done
fi

if [ "$NEEDS_MERGE" = true ]; then
  RUNTIME_HOME="/tmp/claude-runtime-home"
  mkdir -p "$RUNTIME_HOME"
  cp -a "$HOME/." "$RUNTIME_HOME/" 2>/dev/null || true
  mkdir -p "$RUNTIME_HOME/.claude/agents"
  for f in "$BUILTIN_AGENTS_DIR"/*.md; do
    [ -f "$f" ] && cp "$f" "$RUNTIME_HOME/.claude/agents/"
  done
  chown -R node:node "$RUNTIME_HOME"
  echo "  ✓ Built-in agents merged into runtime home"
  exec gosu node env HOME="$RUNTIME_HOME" claude --dangerously-skip-permissions "${MCP_ARGS[@]}" "$@"
fi

exec gosu node claude --dangerously-skip-permissions "${MCP_ARGS[@]}" "$@"