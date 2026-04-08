#!/usr/bin/env python3
"""
credential-guard.py — PreToolUse hook for Claude Code.

Replaces credential-guard.sh + scan-credentials.sh. Single Python process,
precompiled regex, no subprocess spawns.

Usage:
    credential-guard.py write    # scan file content before Write
    credential-guard.py edit     # scan replacement text before Edit
    credential-guard.py bash     # scan command + heredocs before Bash

Hook protocol (native Claude Code):
    stdin: JSON with tool_name, tool_input, session_id, etc.
    exit 0 + no output          → allow
    exit 0 + denial JSON stdout → block
    any crash / scanner error   → allow (fail-open)
"""

import json
import re
import sys

# ── Pattern database ──────────────────────────────────────────
# (compiled_regex, description)
# Sorted by severity: most dangerous first
_RAW_PATTERNS = [
    # Private keys
    (r"-----BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----", "Private key"),
    (r"-----BEGIN CERTIFICATE-----", "Certificate (may contain private material)"),

    # Cloud providers
    (r"AKIA[0-9A-Z]{16}", "AWS Access Key ID"),
    (r"(?i)aws[_\-]?secret[_\-]?access[_\-]?key\s*[=:]\s*[A-Za-z0-9/+=]{30,}", "AWS Secret Access Key"),
    (r"AIza[0-9A-Za-z\-_]{35}", "Google API Key"),
    (r"(?i)(gcloud|google)[_\-]?(api|service|credentials)[_\-]?(key|token|secret)\s*[=:]\s*\S{20,}", "Google Cloud credential"),
    (r"[0-9]+-[0-9A-Za-z_]{32}\.apps\.googleusercontent\.com", "Google OAuth Client ID"),
    (r"ya29\.[0-9A-Za-z\-_]+", "Google OAuth Access Token"),

    # Common API keys
    (r"sk-[A-Za-z0-9]{20,}", "OpenAI / Stripe secret key"),
    (r"sk-ant-[A-Za-z0-9\-]{80,}", "Anthropic API key"),
    (r"sk-proj-[A-Za-z0-9\-]{40,}", "OpenAI project key"),
    (r"ghp_[0-9a-zA-Z]{36}", "GitHub Personal Access Token"),
    (r"gho_[0-9a-zA-Z]{36}", "GitHub OAuth Token"),
    (r"ghs_[0-9a-zA-Z]{36}", "GitHub App Token"),
    (r"ghr_[0-9a-zA-Z]{36}", "GitHub Refresh Token"),
    (r"glpat-[0-9A-Za-z\-]{20,}", "GitLab Personal Access Token"),
    (r"xox[bporas]-[0-9]{10,}-[0-9a-zA-Z]{20,}", "Slack Token"),
    (r"https://hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[a-zA-Z0-9]+", "Slack Webhook URL"),
    (r"SG\.[a-zA-Z0-9\-_]{22}\.[a-zA-Z0-9\-_]{43}", "SendGrid API Key"),
    (r"key-[0-9a-zA-Z]{32}", "Mailgun API Key"),
    (r"sk_live_[0-9a-zA-Z]{24,}", "Stripe Live Secret Key"),
    (r"rk_live_[0-9a-zA-Z]{24,}", "Stripe Restricted Key"),
    (r"sq0csp-[0-9A-Za-z\-_]{43}", "Square OAuth Secret"),
    (r"sqOatp-[0-9A-Za-z\-_]{22}", "Square Access Token"),
    (r"access_token\$production\$[0-9a-z]{16}\$[0-9a-f]{32}", "PayPal / Braintree Access Token"),
    (r"amzn\.mws\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", "Amazon MWS Auth Token"),
    (r"EAACEdEose0cBA[0-9A-Za-z]+", "Facebook Access Token"),
    (r"[0-9]{15,25}:AA[0-9A-Za-z_-]{33}", "Telegram Bot Token"),
    (r"dop_v1_[a-f0-9]{64}", "DigitalOcean Personal Access Token"),
    (r"hf_[A-Za-z0-9]{30,}", "Hugging Face Token"),

    # JWTs
    (r"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}", "JWT Token"),

    # Database connection strings
    (r"(?i)(mysql|postgres|postgresql|mongodb|redis|amqp|mssql)://[^\s:]+:[^\s@]+@[^\s]+", "DB connection string with password"),
    (r"(?i)mongodb\+srv://[^\s:]+:[^\s@]+@[^\s]+", "MongoDB Atlas connection string"),
    (r"(?i)Server=.+;.*Password=.+", "MSSQL connection string with password"),

    # Generic secrets (high confidence)
    (r"""(?i)(api[_\-]?key|api[_\-]?secret|access[_\-]?token|auth[_\-]?token|secret[_\-]?key)\s*[=:]\s*["'][A-Za-z0-9/+=\-_]{20,}["']""", "Hardcoded API key/secret/token"),
    (r"""(?i)(password|passwd|pwd)\s*[=:]\s*["'][^\s"']{8,}["']""", "Hardcoded password"),
    (r"""(?i)(client[_\-]?secret)\s*[=:]\s*["'][A-Za-z0-9\-_]{15,}["']""", "OAuth client secret"),

    # Snowflake / Data warehouse
    (r"(?i)snowflake[_\-]?(password|account|private[_\-]?key)\s*[=:]\s*\S{8,}", "Snowflake credential"),
    (r"(?i)bigquery[_\-]?(credentials|key|token)\s*[=:]\s*\S{8,}", "BigQuery credential"),

    # Webhooks
    (r"https://discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_\-]+", "Discord Webhook URL"),
]

PATTERNS = [(re.compile(pat), desc) for pat, desc in _RAW_PATTERNS]

# ── Allowlist (false-positive reducers) ───────────────────────
_RAW_ALLOWLIST = [
    r"sk-ant-xxxxx",
    r"sk-your-key-here",
    r"YOUR_API_KEY",
    r"your_api_key_here",
    r"PLACEHOLDER",
    r"example\.com",
    r"localhost",
    r"test_.*_test",
    r"\$\{.*\}",
    r"process\.env\.",
    r"os\.environ",
    r"os\.getenv",
    r"ENV\[",
    r"getenv\(",
    r"<YOUR_.*>",
    r"xxx+",
    r"dummy",
    r"changeme",
    r"CHANGE_ME",
    r"REPLACE_ME",
    r"INSERT_.*_HERE",
]

ALLOWLIST = [re.compile(pat, re.IGNORECASE) for pat in _RAW_ALLOWLIST]


# ── Bash content extraction ───────────────────────────────────
# Heredoc: cat << 'EOF' > file ... EOF
_HEREDOC_RE = re.compile(r"<<-?\s*['\"]?(\w+)['\"]?.*?\n(.*?)\n\1", re.DOTALL)
# echo '...' > file
_ECHO_RE = re.compile(r"""echo\s+["'](.*?)["']\s*>>?\s*\S+""", re.DOTALL)
# printf '...' > file
_PRINTF_RE = re.compile(r"""printf\s+["'](.*?)["']\s*>>?\s*\S+""", re.DOTALL)


def extract_bash_write_content(command: str) -> str:
    """Extract content from heredocs, echo>, printf> in a Bash command."""
    chunks = []
    for m in _HEREDOC_RE.finditer(command):
        chunks.append(m.group(2))
    for m in _ECHO_RE.finditer(command):
        chunks.append(m.group(1))
    for m in _PRINTF_RE.finditer(command):
        chunks.append(m.group(1))
    return "\n".join(chunks)


def is_allowlisted(match: str) -> bool:
    return any(pat.search(match) for pat in ALLOWLIST)


def scan(content: str) -> list[tuple[str, str]]:
    """Return list of (description, masked_match) for found credentials."""
    if not content:
        return []

    # Skip binary content (null bytes in first 512 chars)
    head = content[:512]
    if any(ord(c) < 9 or (13 < ord(c) < 32) for c in head if c != "\n" and c != "\t"):
        return []

    findings = []
    for pat, desc in PATTERNS:
        for m in pat.finditer(content):
            match_text = m.group(0)
            if is_allowlisted(match_text):
                continue
            # Mask the secret
            n = len(match_text)
            if n > 16:
                masked = f"{match_text[:6]}...{match_text[-4:]}"
            elif n > 8:
                masked = f"{match_text[:4]}****"
            else:
                masked = "********"
            findings.append((desc, masked))
    return findings


def emit_deny(context: str, findings: list[tuple[str, str]]) -> None:
    """Print Claude Code hook denial JSON to stdout."""
    details = "; ".join(f"{desc} ({masked})" for desc, masked in findings[:5])
    if len(findings) > 5:
        details += f" ... (+{len(findings) - 5} more)"
    reason = (
        f"Credential Guard: Secrets detected in {context}. "
        f"Use environment variables instead. {details}"
    )
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }
    print(json.dumps(output))


def main() -> None:
    try:
        mode = sys.argv[1] if len(sys.argv) > 1 else ""
        if mode not in ("write", "edit", "bash"):
            sys.exit(0)

        hook_input = json.loads(sys.stdin.read())
        tool_input = hook_input.get("tool_input") or {}

        if mode == "write":
            content = tool_input.get("content") or tool_input.get("file_text") or ""
            findings = scan(content)
            if findings:
                emit_deny("file-write", findings)
            sys.exit(0)

        if mode == "edit":
            content = tool_input.get("new_string") or tool_input.get("replacement") or ""
            findings = scan(content)
            if findings:
                emit_deny("edit", findings)
            sys.exit(0)

        if mode == "bash":
            command = tool_input.get("command") or tool_input.get("cmd") or ""
            if not command:
                sys.exit(0)

            # 1. Scan the raw command for inline secrets
            findings = scan(command)
            if findings:
                emit_deny("bash-command", findings)
                sys.exit(0)

            # 2. Scan content written via heredoc/echo/printf
            write_content = extract_bash_write_content(command)
            if write_content:
                findings = scan(write_content)
                if findings:
                    emit_deny("bash-file-write", findings)
                    sys.exit(0)

            sys.exit(0)

    except Exception:
        # Fail-open: any crash in the scanner allows the operation.
        sys.exit(0)


if __name__ == "__main__":
    main()
