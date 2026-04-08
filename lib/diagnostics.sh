# lib/diagnostics.sh — connectivity test, auth check, and banner
# Globals consumed: ALL_DOMAINS, DNS_SERVERS, REFRESH_PID (from lib/firewall.sh)
#                   CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY (env)

diag_print_banner() {
  echo ""
  echo "🔒 Network lock ACTIVE:"
  echo "  ✅ Allowed: ${ALL_DOMAINS//,/, } (HTTPS only)"
  echo "  ✅ Allowed: DNS ($(echo $DNS_SERVERS | tr '\n' ', ' | sed 's/,$//'))"
  echo "  ✅ Allowed: localhost"
  echo "  🚫 Blocked: everything else (IPv4 DROP + IPv6 DROP)"
  echo "  🔄 IP refresh: every 60s (PID $REFRESH_PID)"
  echo ""
}

diag_run_preflight() {
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

  echo "🔑 Auth check:"
  if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
    echo "  ✓ CLAUDE_CODE_OAUTH_TOKEN is set (${CLAUDE_CODE_OAUTH_TOKEN:0:4}...)"
  elif [ -n "$ANTHROPIC_API_KEY" ]; then
    echo "  ✓ ANTHROPIC_API_KEY is set (${ANTHROPIC_API_KEY:0:10}...)"
  else
    echo "  ⚠ No auth token found in environment!"
  fi
  echo ""
}
