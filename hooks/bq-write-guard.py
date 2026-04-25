#!/usr/bin/env python3
"""
bq-write-guard.py — PreToolUse hook for Claude Code.

Defense-in-depth against accidental destructive BigQuery operations issued
through plain `python3 <file.py>` invocations from the Bash tool. The MCP
BigQuery server already restricts writes; the Bash tool bypasses it entirely
when scripts import google.cloud.bigquery directly. This hook scans the
referenced .py file before execution and blocks if it contains write APIs.

Scope (intentional):
    Only `python3 <file.py>` form. Inline `-c "..."`, heredocs, and
    Write/Edit on .py files are out of scope. Real protection is
    least-privilege IAM on the host ADC.

Hook protocol (native Claude Code):
    stdin: JSON with tool_name, tool_input, etc.
    exit 0 + no output          → allow
    exit 0 + denial JSON stdout → block
    any crash / scanner error   → allow (fail-open)
"""

import json
import os
import re
import shlex
import sys

_RAW_PATTERNS = [
    (r"\.delete_(?:table|dataset|model|routine|job)\s*\(",
     "BigQuery delete_*"),
    (r"\.update_(?:table|dataset|model|routine)\s*\(",
     "BigQuery update_*"),
    (r"\.create_(?:table|dataset|model|routine)\s*\(",
     "BigQuery create_* (DDL)"),
    (r"\.copy_table\s*\(",
     "BigQuery copy_table"),
    (r"\.insert_rows\w*\s*\(",
     "BigQuery insert_rows*"),
    (r"\.load_table_from_\w+\s*\(",
     "BigQuery load_table_from_*"),
    (r"\.query(?:_and_wait)?\s*\(\s*[fbruRBU]*['\"]\s*"
     r"(?:DELETE|DROP|TRUNCATE|UPDATE|INSERT|MERGE|ALTER|CREATE|GRANT|REVOKE|REPLACE)\b",
     "BigQuery write SQL via .query()"),
    (r"\b(?:requests|httpx|urllib3|aiohttp)\.[A-Za-z_]*\.?(?:delete|patch|put|post)"
     r"\s*\([^)]{0,300}bigquery\.googleapis\.com",
     "Direct BigQuery REST write"),
]

PATTERNS = [(re.compile(p, re.IGNORECASE), desc) for p, desc in _RAW_PATTERNS]

_PY_INTERP_RE = re.compile(r"^python(\d+(\.\d+)?)?$")
_FLAGS_WITH_VALUE = {"-c", "-m", "-W", "-X", "--check-hash-based-pycs"}
_MAX_FILE_BYTES = 1_000_000


def find_python_script(command: str) -> str | None:
    """Return path to the .py file passed to a python interpreter, or None.

    Returns None for `-c`, `-m`, missing files, or unparseable commands.
    """
    try:
        parts = shlex.split(command, posix=True)
    except ValueError:
        return None

    i = 0
    while i < len(parts):
        base = os.path.basename(parts[i])
        if not _PY_INTERP_RE.match(base):
            i += 1
            continue

        j = i + 1
        while j < len(parts):
            arg = parts[j]
            if arg.startswith("-"):
                if arg in ("-c", "-m"):
                    return None
                if arg in _FLAGS_WITH_VALUE:
                    j += 2
                    continue
                j += 1
                continue
            if arg.endswith(".py") and os.path.isfile(arg):
                return arg
            return None
        i += 1

    return None


def scan(content: str) -> list[tuple[str, str]]:
    findings = []
    for pat, desc in PATTERNS:
        m = pat.search(content)
        if m:
            snippet = m.group(0)
            if len(snippet) > 80:
                snippet = snippet[:77] + "..."
            findings.append((desc, snippet))
    return findings


def emit_deny(script_path: str, findings: list[tuple[str, str]]) -> None:
    details = "; ".join(f"{desc}: `{snippet}`" for desc, snippet in findings[:5])
    if len(findings) > 5:
        details += f" ... (+{len(findings) - 5} more)"
    reason = (
        f"BigQuery Write Guard: destructive/write API call detected in "
        f"{script_path}. Use the bigquery MCP server (read-only by default, "
        f"write tools are dataset-scoped) instead of the SDK. Findings: {details}"
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
        hook_input = json.loads(sys.stdin.read())
        tool_input = hook_input.get("tool_input") or {}
        command = tool_input.get("command") or tool_input.get("cmd") or ""
        if not command:
            sys.exit(0)

        script_path = find_python_script(command)
        if not script_path:
            sys.exit(0)

        try:
            with open(script_path, "rb") as f:
                content = f.read(_MAX_FILE_BYTES).decode("utf-8", errors="replace")
        except OSError:
            sys.exit(0)

        findings = scan(content)
        if findings:
            emit_deny(script_path, findings)
        sys.exit(0)

    except Exception:
        sys.exit(0)


if __name__ == "__main__":
    main()
