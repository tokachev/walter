"""
audit.py — Append-only audit log for all tool calls.

Structure per entry:
  timestamp, tool_name, input_hash (SHA-256), output_hash, latency_ms, token_count

Writes JSONL to /var/log/walter/audit.jsonl (configurable via WALTER_AUDIT_LOG).
"""

import hashlib
import json
import os
import time
from pathlib import Path

AUDIT_LOG_PATH = os.getenv("WALTER_AUDIT_LOG", "/var/log/walter/audit.jsonl")


def _ensure_log_dir():
    Path(AUDIT_LOG_PATH).parent.mkdir(parents=True, exist_ok=True)


def _hash(data: str) -> str:
    """SHA-256 hash of input string."""
    return hashlib.sha256(data.encode("utf-8", errors="replace")).hexdigest()


def log_tool_call(
    tool_name: str,
    tool_input: dict,
    *,
    output: str = "",
    latency_ms: float = 0,
    token_count: int = 0,
    session_id: str = "",
    blocked: bool = False,
    block_reason: str = "",
):
    """Append a single audit entry to the JSONL log."""
    _ensure_log_dir()

    entry = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "epoch": time.time(),
        "tool": tool_name,
        "input_hash": _hash(json.dumps(tool_input, sort_keys=True, default=str)),
        "output_hash": _hash(output) if output else "",
        "latency_ms": round(latency_ms, 1),
        "token_count": token_count,
        "session_id": session_id,
        "blocked": blocked,
        "block_reason": block_reason,
    }

    try:
        with open(AUDIT_LOG_PATH, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError:
        # Fail-open: audit failure must not block operations
        pass


def read_recent_entries(seconds: int = 300, tool_filter: str = "") -> list[dict]:
    """Read audit entries from the last N seconds, optionally filtered by tool name.

    Reads only the last ~200 lines to avoid scanning the entire file on every check.
    """
    cutoff = time.time() - seconds
    entries = []

    try:
        with open(AUDIT_LOG_PATH, "rb") as f:
            # Seek to the tail: read last ~64KB (enough for ~200 entries)
            try:
                f.seek(-65536, 2)
                # Skip partial first line
                f.readline()
            except OSError:
                f.seek(0)

            for raw_line in f:
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                    if entry.get("epoch", 0) >= cutoff:
                        if not tool_filter or entry.get("tool") == tool_filter:
                            entries.append(entry)
                except (json.JSONDecodeError, KeyError):
                    continue
    except FileNotFoundError:
        pass

    return entries
