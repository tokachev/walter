#!/usr/bin/env bash
# safe-load-env.sh — Safe .env parser (no shell execution)
#
# Parses KEY=VALUE pairs without shell execution (no source/eval).
# Handles: empty lines, comments, export prefix, single/double quotes,
# inline comments on unquoted values. Malicious payloads ($(...), `...`)
# are kept as literal strings and never executed.
#
# Usage:
#   source hooks/lib/safe-load-env.sh
#   safe_load_env /path/to/.env [KEY1 KEY2 ...]   # optional space-separated whitelist

safe_load_env() {
  local env_file="$1"
  local whitelist="${2:-}"  # optional space-separated list of allowed keys
  [ -f "$env_file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip empty lines and comment lines
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    # Strip leading whitespace and optional 'export ' prefix
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#export }"
    # Must match KEY=... (KEY: alphanumeric + underscore, starting with letter/underscore)
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*) ]] || continue
    local key="${BASH_REMATCH[1]}"
    local val="${BASH_REMATCH[2]}"
    # Double-quoted value: strip quotes, no inline-comment stripping
    if [[ "$val" =~ ^\"(.*) ]]; then
      val="${val#\"}"
      val="${val%\"}"
    # Single-quoted value: strip quotes, no inline-comment stripping
    elif [[ "$val" =~ ^\'(.*) ]]; then
      val="${val#\'}"
      val="${val%\'}"
    else
      # Unquoted: strip inline comment (space + # + anything)
      val="${val%% #*}"
      # Trim trailing whitespace
      val="${val%"${val##*[![:space:]]}"}"
    fi
    # If whitelist given, skip keys not in it
    if [ -n "$whitelist" ]; then
      local allowed=false
      local w
      for w in $whitelist; do
        [ "$key" = "$w" ] && allowed=true && break
      done
      [ "$allowed" = false ] && continue
    fi
    export "$key=$val"
  done < "$env_file"
}
