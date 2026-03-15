"""
audit.py — Append-only audit log for all tool calls.

Writes JSONL to /var/log/walter/audit.jsonl (configurable via WALTER_AUDIT_LOG).
Each entry includes full tool_input (with large content fields truncated)
and a human-readable summary for dashboard display.
"""

import copy
import fcntl
import hashlib
import json
import os
import time
from pathlib import Path

AUDIT_LOG_PATH = os.getenv("WALTER_AUDIT_LOG", "/var/log/walter/audit.jsonl")

_TRUNCATE_KEYS = {"content", "new_string", "old_string", "prompt"}
_TRUNCATE_LINES = 20


def _ensure_log_dir():
    Path(AUDIT_LOG_PATH).parent.mkdir(parents=True, exist_ok=True)


def _hash(data: str) -> str:
    return hashlib.sha256(data.encode("utf-8", errors="replace")).hexdigest()


def _truncate_tool_input(tool_input: dict) -> dict:
    """Shallow-copy tool_input, truncate large string fields."""
    tool_input = tool_input or {}
    result = copy.copy(tool_input)
    for key in _TRUNCATE_KEYS:
        val = result.get(key)
        if not isinstance(val, str):
            continue
        lines = val.split("\n")
        if len(lines) > _TRUNCATE_LINES:
            result[key] = "\n".join(lines[:_TRUNCATE_LINES]) + f"\n…(truncated, {len(lines)} lines total)"
    return result


def _extract_summary(tool_name: str, tool_input: dict) -> str:
    """One-line human-readable summary of what the tool call does."""
    s = ""
    ti = tool_input or {}
    if tool_name == "Read":
        s = ti.get("file_path", "")
        if ti.get("offset") or ti.get("limit"):
            parts = []
            if ti.get("offset"):
                parts.append(f"offset={ti['offset']}")
            if ti.get("limit"):
                parts.append(f"limit={ti['limit']}")
            s += f" ({', '.join(parts)})"
    elif tool_name in ("Write", "NotebookEdit"):
        s = ti.get("file_path", "")
    elif tool_name == "Edit":
        s = ti.get("file_path", "")
        old = (ti.get("old_string") or "").replace("\n", " ").strip()
        new = (ti.get("new_string") or "").replace("\n", " ").strip()
        if old or new:
            s += ': "' + old[:60] + ('"…' if len(old) > 60 else '"')
            s += '→"' + new[:60] + ('"…' if len(new) > 60 else '"')
    elif tool_name == "Bash":
        s = ti.get("description") or ti.get("command", "")
    elif tool_name == "Grep":
        pattern = ti.get("pattern", "")
        path = ti.get("path", ".")
        s = f'"{pattern}" in {path}'
    elif tool_name == "Glob":
        s = ti.get("pattern", "")
        if ti.get("path"):
            s += f" in {ti['path']}"
    elif tool_name == "Agent":
        agent_type = ti.get("subagent_type", "")
        desc = ti.get("description", "")
        s = f"[{agent_type}] {desc}" if agent_type else desc
    elif tool_name == "WebFetch":
        s = ti.get("url", "")
    elif tool_name == "WebSearch":
        s = ti.get("query", "")
    elif tool_name == "Skill":
        s = ti.get("skill_name", "")
    if len(s) > 200:
        s = s[:197] + "…"
    return s


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
        "tool_input": _truncate_tool_input(tool_input),
        "summary": _extract_summary(tool_name, tool_input),
        "latency_ms": round(latency_ms, 1),
        "token_count": token_count,
        "session_id": session_id,
        "blocked": blocked,
        "block_reason": block_reason,
    }

    try:
        with open(AUDIT_LOG_PATH, "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
            f.flush()
            fcntl.flock(f, fcntl.LOCK_UN)
    except OSError:
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
