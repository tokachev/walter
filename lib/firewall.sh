# ══════════════════════════════════════════════════════════════
#  lib/firewall.sh — sourceable firewall library
#
#  Exports:
#    resolve_domains <csv_domains>
#    firewall_init <csv_domains>
#    firewall_allow_domain <csv_domains>
#    firewall_start_refresh_loop
#
#  Global state set by firewall_init:
#    DNS_SERVERS         — space-separated nameserver IPs
#    ALLOWED_IPS_FILE    — path to tracked-IPs file
#    REFRESH_PID         — PID of background refresh loop (set by firewall_start_refresh_loop)
# ══════════════════════════════════════════════════════════════

# resolve_domains <csv_domains>
#   Resolves each domain via dig + getent. Prints resolved IPs, one per line.
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

# firewall_init <csv_domains>
#   Full initial setup: IPv6 block, discover DNS servers, resolve domains,
#   write ALLOWED_IPS_FILE, apply IPv4 iptables rules (loopback, established,
#   DNS, HTTPS to resolved IPs, LOG+REJECT tail), run Python warmup resolver.
#   Exits 1 if no domains resolve and stdin is not a TTY.
firewall_init() {
  local csv_domains="$1"
  ALLOWED_IPS_FILE="${ALLOWED_IPS_FILE:=/tmp/.walter-allowed-ips}"

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

  : > "$ALLOWED_IPS_FILE"

  echo "  Resolving allowed domains..."
  INITIAL_IPS=$(resolve_domains "$csv_domains")

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
    IFS=',' read -ra DARR <<< "$csv_domains"
    for domain in "${DARR[@]}"; do
      domain=$(echo "$domain" | xargs)
      if dig +short "$domain" 2>/dev/null | grep -q "$ip"; then
        echo "  ✓ $domain → $ip"
        break
      fi
    done
  done

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
domains = '${csv_domains}'.split(',')
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
  if [ "$WARMUP_ADDED" -gt 0 ]; then
    echo "  + $WARMUP_ADDED extra IPs from Python resolver"
  fi
}

# firewall_allow_domain <csv_domains>
#   Dynamically adds iptables ACCEPT rules for a comma-separated list of new
#   domains. Idempotent. Used by MCP config step to add BQ/Snowflake domains
#   after firewall_init has run. Appends to ALLOWED_IPS_FILE.
firewall_allow_domain() {
  local csv_domains="$1"
  local IPS
  IPS=$(resolve_domains "$csv_domains")
  for ip in $IPS; do
    if ! grep -q "^${ip}$" "$ALLOWED_IPS_FILE" 2>/dev/null; then
      iptables -I OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT 2>/dev/null || true
      echo "$ip" >> "$ALLOWED_IPS_FILE"
    fi
  done
}

# firewall_start_refresh_loop
#   Spawns a background loop that re-resolves ALL_DOMAINS every 60s and
#   appends any new IPs to iptables + ALLOWED_IPS_FILE. Sets REFRESH_PID.
#   Uses the global ALL_DOMAINS variable from the caller.
firewall_start_refresh_loop() {
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
}
