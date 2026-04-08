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
    # Method 1: dig (explicit DNS protocol query)
    for dns in $DNS_SERVERS; do
      NEW_IPS=$(dig +short @"$dns" "$domain" 2>/dev/null | grep -E '^[0-9]+\.' || true)
      [ -n "$NEW_IPS" ] && ips="$ips $NEW_IPS" && break
    done
    # Method 2: getent ahosts (libc resolver — matches Python/curl behavior)
    NEW_IPS=$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.' || true)
    [ -n "$NEW_IPS" ] && ips="$ips $NEW_IPS"
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
    sleep 60
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

# REJECT everything else (REJECT returns immediate error; DROP hangs until TCP timeout)
# Critical: Claude Code connects to telemetry (segment.io, growthbook.io, datadoghq.com)
# With DROP, each blocked connection hangs 60-120s. With REJECT, it fails in 0.02s.
iptables -A OUTPUT -j LOG --log-prefix "WALTER-BLOCKED: " --log-level 4 2>/dev/null || true
iptables -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset
iptables -A OUTPUT -j REJECT --reject-with icmp-port-unreachable
iptables -A INPUT -p tcp -j REJECT --reject-with tcp-reset
iptables -A INPUT -j REJECT --reject-with icmp-port-unreachable

# ── Warmup: Python resolver (matches google-cloud-bigquery behavior) ──
WARMUP_IPS=$(python3 -c "
import socket
domains = '${ALL_DOMAINS}'.split(',')
seen = set()
for d in domains:
    d = d.strip()
    try:
        for info in socket.getaddrinfo(d, 443, socket.AF_INET):
            ip = info[4][0]
            if ip not in seen:
                seen.add(ip)
                print(ip)
    except:
        pass
" 2>/dev/null || true)

WARMUP_ADDED=0
for ip in $WARMUP_IPS; do
  if ! grep -q "^${ip}$" "$ALLOWED_IPS_FILE" 2>/dev/null; then
    iptables -I OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT 2>/dev/null || true
    echo "$ip" >> "$ALLOWED_IPS_FILE"
    WARMUP_ADDED=$((WARMUP_ADDED + 1))
  fi
done
[ "$WARMUP_ADDED" -gt 0 ] && echo "  + $WARMUP_ADDED extra IPs from Python resolver"

echo ""
echo "🔒 Network lock ACTIVE:"
echo "  ✅ Allowed: ${ALL_DOMAINS//,/, } (HTTPS only)"
echo "  ✅ Allowed: DNS ($(echo $DNS_SERVERS | tr '\n' ', ' | sed 's/,$//'))"
echo "  ✅ Allowed: localhost"
echo "  🚫 Blocked: everything else (IPv4 DROP + IPv6 DROP)"
echo "  🔄 IP refresh: every 60s (PID $REFRESH_PID)"
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
  echo "  ✓ CLAUDE_CODE_OAUTH_TOKEN is set (${CLAUDE_CODE_OAUTH_TOKEN:0:4}...)"
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
  MERGED=$(jq -s '
    .[0] * .[1]
    | .hooks = (.[0].hooks // {}) * (.[1].hooks // {})
    | .statusLine = (.[1].statusLine // .[0].statusLine // null)
    | if .statusLine == null then del(.statusLine) else . end
  ' "$HOST_SETTINGS" "$CONTAINER_SETTINGS" 2>/dev/null) || true
  if [ -n "$MERGED" ]; then
    echo "$MERGED" > "$CONTAINER_SETTINGS"
    echo "  ✓ Settings merged (host preferences + container hooks)"
  fi
elif [ -f "$HOST_SETTINGS" ]; then
  cp "$HOST_SETTINGS" "$CONTAINER_SETTINGS"
  echo "  ✓ Host settings applied"
fi

# ── Auto-memory ──────────────────────────────────────────────
# Auto-memory uses the native Claude Code path /opt/claude-home/.claude/
# projects/-workspace/memory/ (derived from WORKDIR=/workspace).  Walter
# bind-mounts the matching host-side memory directory onto that path, so
# there is nothing to configure here — Walter and native host CLI sessions
# share the same memory dir directly.

# ── Git safe.directory ───────────────────────────────────────
# The mounted project is owned by the host UID which differs from the container
# user.  Git 2.35.2+ refuses to operate without an explicit exception.
git config --global --add safe.directory /workspace 2>/dev/null || true

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

# ── MCP: BigQuery server ─────────────────────────────────────
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
  BQ_IPS=$(resolve_domains "$BQ_DOMAINS")
  for ip in $BQ_IPS; do
    iptables -I OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT 2>/dev/null || true
    echo "$ip" >> "$ALLOWED_IPS_FILE"
  done
  echo "  ✓ BigQuery API domains added to firewall allowlist"
  echo ""
fi

# ── MCP: Data Detective ─────────────────────────────────────
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
    SF_IPS=$(resolve_domains "$SF_DOMAIN")
    for ip in $SF_IPS; do
      iptables -I OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT 2>/dev/null || true
      echo "$ip" >> "$ALLOWED_IPS_FILE"
    done
    echo "  ✓ Snowflake domain added to firewall allowlist"
  fi

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

# ── Write MCP config if any servers registered ───────────────
HAS_MCP=$(echo "$MCP_JSON" | jq '.mcpServers | length')
if [ "$HAS_MCP" -gt 0 ]; then
  echo "$MCP_JSON" > "$MCP_CONFIG"
  MCP_ARGS=(--mcp-config "$MCP_CONFIG")
fi

# ── Ensure built-in files survive host mounts ─────────────────
# If host mounted ~/.claude/agents or ~/.claude/commands (read-only),
# they shadow the Dockerfile copies. Merge built-in files into a writable dir.
AGENTS_DIR="$HOME/.claude/agents"
COMMANDS_DIR="$HOME/.claude/commands"
BUILTIN_AGENTS_DIR="/opt/detective"
BUILTIN_COMMANDS_DIR="/opt/sdd/commands"
BUILTIN_SDD_AGENTS="/opt/sdd/agents"
BUILTIN_ROOT_COMMANDS="/opt/commands"
NEEDS_MERGE=false

# Host-mounted ~/.claude/agents or ~/.claude/commands should always be merged
# into a writable runtime home so repo-owned Walter files can override stale
# duplicates from the host while preserving host-only custom files.
if [ -n "${WALTER_HOST_AGENTS_MOUNTED:-}" ] || [ -n "${WALTER_HOST_COMMANDS_MOUNTED:-}" ]; then
  NEEDS_MERGE=true
fi

# Check if built-in agents need merging
if [ "$NEEDS_MERGE" != true ] && [ -d "$AGENTS_DIR" ] && [ -d "$BUILTIN_AGENTS_DIR" ]; then
  for f in "$BUILTIN_AGENTS_DIR"/*.md; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    if [ ! -f "$AGENTS_DIR/$fname" ]; then
      NEEDS_MERGE=true
      break
    fi
  done
fi

# Check if built-in SDD agents need merging
if [ "$NEEDS_MERGE" != true ] && [ -d "$AGENTS_DIR" ] && [ -d "$BUILTIN_SDD_AGENTS" ]; then
  for f in "$BUILTIN_SDD_AGENTS"/*.md; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    if [ ! -f "$AGENTS_DIR/$fname" ]; then
      NEEDS_MERGE=true
      break
    fi
  done
fi

# Check if built-in SDD commands need merging
if [ "$NEEDS_MERGE" != true ] && [ -d "$COMMANDS_DIR" ] && [ -d "$BUILTIN_COMMANDS_DIR" ]; then
  for f in "$BUILTIN_COMMANDS_DIR"/*.md; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    if [ ! -f "$COMMANDS_DIR/sdd/$fname" ]; then
      NEEDS_MERGE=true
      break
    fi
  done
fi

# Check if built-in root commands (peer-review etc.) need merging
if [ "$NEEDS_MERGE" != true ] && [ -d "$COMMANDS_DIR" ] && [ -d "$BUILTIN_ROOT_COMMANDS" ]; then
  for f in "$BUILTIN_ROOT_COMMANDS"/*.md; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    if [ ! -f "$COMMANDS_DIR/$fname" ]; then
      NEEDS_MERGE=true
      break
    fi
  done
fi

# ── Compute effective HOME ───────────────────────────────────
EFFECTIVE_HOME="$HOME"

if [ "$NEEDS_MERGE" = true ]; then
  RUNTIME_HOME="/opt/claude-runtime-home"
  mkdir -p "$RUNTIME_HOME/.claude"

  # Copy HOME selectively — skip .claude/projects (mounted volume, can be huge)
  # Copy top-level files
  for f in "$HOME"/.* "$HOME"/*; do
    fname=$(basename "$f")
    [ "$fname" = "." ] || [ "$fname" = ".." ] && continue
    [ "$fname" = ".claude" ] && continue
    cp -a "$f" "$RUNTIME_HOME/" 2>/dev/null || true
  done
  # Copy .claude/ contents except projects/
  for f in "$HOME/.claude"/*; do
    fname=$(basename "$f")
    [ "$fname" = "projects" ] && continue
    cp -a "$f" "$RUNTIME_HOME/.claude/" 2>/dev/null || true
  done

  # Merge built-in agents
  mkdir -p "$RUNTIME_HOME/.claude/agents"
  for f in "$BUILTIN_AGENTS_DIR"/*.md; do
    [ -f "$f" ] && cp "$f" "$RUNTIME_HOME/.claude/agents/"
  done
  for f in "$BUILTIN_SDD_AGENTS"/*.md; do
    [ -f "$f" ] && cp "$f" "$RUNTIME_HOME/.claude/agents/"
  done

  # Merge built-in commands
  mkdir -p "$RUNTIME_HOME/.claude/commands/sdd"
  for f in "$BUILTIN_COMMANDS_DIR"/*.md; do
    [ -f "$f" ] && cp "$f" "$RUNTIME_HOME/.claude/commands/sdd/"
  done
  # Merge root commands (peer-review etc.)
  for f in "$BUILTIN_ROOT_COMMANDS"/*.md; do
    [ -f "$f" ] && cp "$f" "$RUNTIME_HOME/.claude/commands/"
  done

  # Symlink projects back to the mounted volume so session data persists
  ln -s "$HOME/.claude/projects" "$RUNTIME_HOME/.claude/projects"
  chown -R -h node:node "$RUNTIME_HOME"
  echo "  ✓ Built-in agents + commands merged into runtime home"
  EFFECTIVE_HOME="$RUNTIME_HOME"
fi

# ── Launch ──────────────────────────────────────────────────
CLAUDE_BASE_ARGS="--dangerously-skip-permissions --effort high ${MCP_ARGS[*]}"

if [ -n "${WALTER_REVIEW_ONLY:-}" ]; then
  # Review-only mode: skip plan execution, run review directly
  export WALTER_CLAUDE_ARGS_STR="$CLAUDE_BASE_ARGS"
  exec gosu node env HOME="$EFFECTIVE_HOME" /opt/review/review-executor.sh
elif [ -n "${WALTER_PLAN_FILE:-}" ]; then
  # Plan execution mode: delegate to plan-executor.sh
  export WALTER_CLAUDE_ARGS_STR="$CLAUDE_BASE_ARGS"
  exec gosu node env HOME="$EFFECTIVE_HOME" /opt/plan-executor.sh
else
  exec gosu node env HOME="$EFFECTIVE_HOME" claude --dangerously-skip-permissions --effort high "${MCP_ARGS[@]}" "$@"
fi
