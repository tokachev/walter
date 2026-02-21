#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  Credential Scanner — blocks files/commands containing secrets
#  Called by Claude Code PreToolUse hook
#
#  Exit 0 = clean, Exit 1 = credentials found (BLOCKS execution)
#
#  Detects: API keys, tokens, passwords, private keys, connection
#  strings, cloud credentials, webhook URLs, JWTs, and more.
# ══════════════════════════════════════════════════════════════

set -euo pipefail

CONTENT="$1"  # file path or "-" for stdin
CONTEXT="${2:-file}"  # "file" or "command"

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ── Pattern database ──────────────────────────────────────────
# Each pattern: "REGEX|||DESCRIPTION"
# Sorted by severity: most dangerous first

PATTERNS=(
  # ── Private keys ────────────────────────────────────────────
  '-----BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----|||Private key detected'
  '-----BEGIN CERTIFICATE-----|||Certificate detected (may contain private material)'

  # ── Cloud providers ─────────────────────────────────────────
  'AKIA[0-9A-Z]{16}|||AWS Access Key ID'
  '(?i)aws[_\-]?secret[_\-]?access[_\-]?key\s*[=:]\s*[A-Za-z0-9/+=]{30,}|||AWS Secret Access Key'
  'AIza[0-9A-Za-z\-_]{35}|||Google API Key'
  '(?i)(gcloud|google)[_\-]?(api|service|credentials)[_\-]?(key|token|secret)\s*[=:]\s*\S{20,}|||Google Cloud credential'
  '[0-9]+-[0-9A-Za-z_]{32}\.apps\.googleusercontent\.com|||Google OAuth Client ID'
  'ya29\.[0-9A-Za-z\-_]+|||Google OAuth Access Token'

  # ── Common API keys ─────────────────────────────────────────
  'sk-[A-Za-z0-9]{20,}|||OpenAI / Stripe secret key'
  'sk-ant-[A-Za-z0-9\-]{80,}|||Anthropic API key'
  'sk-proj-[A-Za-z0-9\-]{40,}|||OpenAI project key'
  'ghp_[0-9a-zA-Z]{36}|||GitHub Personal Access Token'
  'gho_[0-9a-zA-Z]{36}|||GitHub OAuth Token'
  'ghs_[0-9a-zA-Z]{36}|||GitHub App Token'
  'ghr_[0-9a-zA-Z]{36}|||GitHub Refresh Token'
  'glpat-[0-9A-Za-z\-]{20,}|||GitLab Personal Access Token'
  'xox[bporas]-[0-9]{10,}-[0-9a-zA-Z]{20,}|||Slack Token'
  'https://hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[a-zA-Z0-9]+|||Slack Webhook URL'
  'SG\.[a-zA-Z0-9\-_]{22}\.[a-zA-Z0-9\-_]{43}|||SendGrid API Key'
  'key-[0-9a-zA-Z]{32}|||Mailgun API Key'
  'sk_live_[0-9a-zA-Z]{24,}|||Stripe Live Secret Key'
  'rk_live_[0-9a-zA-Z]{24,}|||Stripe Restricted Key'
  'sq0csp-[0-9A-Za-z\-_]{43}|||Square OAuth Secret'
  'sqOatp-[0-9A-Za-z\-_]{22}|||Square Access Token'
  'access_token\$production\$[0-9a-z]{16}\$[0-9a-f]{32}|||PayPal / Braintree Access Token'
  'amzn\.mws\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|||Amazon MWS Auth Token'
  'EAACEdEose0cBA[0-9A-Za-z]+|||Facebook Access Token'
  'AAAT[a-zA-Z0-9]+|||Instagram Access Token'
  '[0-9]{15,25}:AA[0-9A-Za-z_-]{33}|||Telegram Bot Token'
  'dop_v1_[a-f0-9]{64}|||DigitalOcean Personal Access Token'
  'hf_[A-Za-z0-9]{30,}|||Hugging Face Token'

  # ── JWTs and bearer tokens ──────────────────────────────────
  'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|||JWT Token'

  # ── Database connection strings ─────────────────────────────
  '(?i)(mysql|postgres|postgresql|mongodb|redis|amqp|mssql)://[^\s:]+:[^\s@]+@[^\s]+|||Database connection string with password'
  '(?i)mongodb\+srv://[^\s:]+:[^\s@]+@[^\s]+|||MongoDB Atlas connection string'
  '(?i)Server=.+;.*Password=.+|||MSSQL connection string with password'

  # ── Generic secrets (high confidence) ───────────────────────
  '(?i)(api[_\-]?key|api[_\-]?secret|access[_\-]?token|auth[_\-]?token|secret[_\-]?key)\s*[=:]\s*["\x27][A-Za-z0-9/+=\-_]{20,}["\x27]|||Hardcoded API key/secret/token'
  '(?i)(password|passwd|pwd)\s*[=:]\s*["\x27][^\s"'\'']{8,}["\x27]|||Hardcoded password'
  '(?i)(client[_\-]?secret)\s*[=:]\s*["\x27][A-Za-z0-9\-_]{15,}["\x27]|||OAuth client secret'

  # ── Snowflake / Data warehouse ──────────────────────────────
  '(?i)snowflake[_\-]?(password|account|private[_\-]?key)\s*[=:]\s*\S{8,}|||Snowflake credential'
  '(?i)bigquery[_\-]?(credentials|key|token)\s*[=:]\s*\S{8,}|||BigQuery credential'

  # ── Webhook URLs (general) ──────────────────────────────────
  'https://discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_\-]+|||Discord Webhook URL'
)

# ── Allowlist patterns (reduce false positives) ───────────────
ALLOWLIST_PATTERNS=(
  'sk-ant-xxxxx'           # Placeholder examples
  'sk-your-key-here'
  'YOUR_API_KEY'
  'your_api_key_here'
  'PLACEHOLDER'
  'example\.com'
  'localhost'
  'test_.*_test'
  '\$\{.*\}'               # Variable interpolation ${VAR}
  'process\.env\.'         # Env var references
  'os\.environ'
  'os\.getenv'
  'ENV\['
  'getenv\('
  '<YOUR_.*>'
  'xxx+'
  'dummy'
  'changeme'
  'CHANGE_ME'
  'REPLACE_ME'
  'INSERT_.*_HERE'
)

# ── Read content ──────────────────────────────────────────────
if [ "$CONTENT" = "-" ]; then
  INPUT=$(cat)
else
  if [ ! -f "$CONTENT" ]; then
    exit 0  # File doesn't exist yet, nothing to scan
  fi
  INPUT=$(cat "$CONTENT" 2>/dev/null || echo "")
fi

if [ -z "$INPUT" ]; then
  exit 0
fi

# ── Skip binary files ────────────────────────────────────────
if echo "$INPUT" | head -c 512 | grep -qP '[\x00-\x08\x0E-\x1F]'; then
  exit 0
fi

# ── Check allowlist ──────────────────────────────────────────
is_allowlisted() {
  local match="$1"
  for pattern in "${ALLOWLIST_PATTERNS[@]}"; do
    if echo "$match" | grep -qiP "$pattern" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# ── Scan ──────────────────────────────────────────────────────
FOUND=()
FOUND_COUNT=0

for entry in "${PATTERNS[@]}"; do
  REGEX="${entry%%|||*}"
  DESC="${entry##*|||}"
  
  # Find matches
  MATCHES=$(echo "$INPUT" | grep -oP "$REGEX" 2>/dev/null || true)
  
  if [ -n "$MATCHES" ]; then
    while IFS= read -r match; do
      if ! is_allowlisted "$match"; then
        FOUND+=("$DESC")
        FOUND_COUNT=$((FOUND_COUNT + 1))
        
        # Mask the credential for display (show first 6 and last 4 chars)
        MATCH_LEN=${#match}
        if [ "$MATCH_LEN" -gt 16 ]; then
          MASKED="${match:0:6}...$(echo "$match" | tail -c 5)"
        elif [ "$MATCH_LEN" -gt 8 ]; then
          MASKED="${match:0:4}****"
        else
          MASKED="********"
        fi
        
        # Print to stderr (visible in Claude Code output)
        echo -e "${RED}🚨 BLOCKED: ${DESC}${NC}" >&2
        echo -e "   Match: ${YELLOW}${MASKED}${NC}" >&2
        echo "" >&2
      fi
    done <<< "$MATCHES"
  fi
done

# ── Result ────────────────────────────────────────────────────
if [ "$FOUND_COUNT" -gt 0 ]; then
  echo -e "${RED}═══════════════════════════════════════════════${NC}" >&2
  echo -e "${RED}  🛑 CREDENTIAL GUARD: Blocked ${FOUND_COUNT} secret(s)${NC}" >&2
  echo -e "${RED}     Context: ${CONTEXT}${NC}" >&2
  echo -e "${RED}═══════════════════════════════════════════════${NC}" >&2
  echo -e "" >&2
  echo -e "  Use environment variables or a secrets manager instead." >&2
  echo -e "  If this is a false positive, add to allowlist in:" >&2
  echo -e "  ~/.claude/hooks/credential-guard/scan-credentials.sh" >&2
  exit 1
fi

exit 0
