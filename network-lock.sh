#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  network-lock.sh — thin router for container startup
#
#  Delegates to lib/ modules:
#    lib/firewall.sh       — iptables + DNS + IP refresh loop
#    lib/mcp-config.sh     — MCP server registration
#    lib/diagnostics.sh    — connectivity test + auth check + banner
#    lib/settings-merge.sh — host settings + agents/commands merge
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

# ── Source library modules ────────────────────────────────────
LIB_DIR="${WALTER_LIB_DIR:-/opt/lib}"
# Fallback for development/tests: if /opt/lib doesn't exist, try script-adjacent lib/
if [ ! -d "$LIB_DIR" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -d "$SCRIPT_DIR/lib" ] && LIB_DIR="$SCRIPT_DIR/lib"
fi

# shellcheck source=/dev/null
source "$LIB_DIR/firewall.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/mcp-config.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/diagnostics.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/settings-merge.sh"

# ── Startup sequence ──────────────────────────────────────────
firewall_init "$ALL_DOMAINS"
# NOTE: refresh loop forks here — gets a snapshot of ALL_DOMAINS at this point.
# MCP blocks that add extra domains (BQ, Snowflake) handle their own immediate
# firewall_allow_domain calls; the refresh loop only covers base domains.
firewall_start_refresh_loop
diag_print_banner
diag_run_preflight

# Git safe.directory for host-owned mounts
git config --global --add safe.directory /workspace 2>/dev/null || true

# MCP servers (may call firewall_allow_domain for additional domains)
mcp_generate_config

# Settings + agents/commands merge (computes EFFECTIVE_HOME)
settings_merge_host_overrides

# ── Launch ────────────────────────────────────────────────────
CLAUDE_BASE_ARGS="--dangerously-skip-permissions --effort high ${MCP_ARGS[*]}"

if [ -n "${WALTER_REVIEW_ONLY:-}" ]; then
  export WALTER_CLAUDE_ARGS_STR="$CLAUDE_BASE_ARGS"
  exec gosu node env HOME="$EFFECTIVE_HOME" /opt/review/review-executor.sh
elif [ -n "${WALTER_PLAN_FILE:-}" ]; then
  export WALTER_CLAUDE_ARGS_STR="$CLAUDE_BASE_ARGS"
  exec gosu node env HOME="$EFFECTIVE_HOME" /opt/plan-executor.sh
else
  exec gosu node env HOME="$EFFECTIVE_HOME" claude --dangerously-skip-permissions --effort high "${MCP_ARGS[@]}" "$@"
fi
