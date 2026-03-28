"""
correction_detector.py — Detects self-corrections: when Claude edits what it just wrote.

Pattern: Edit(file=X, new_string=A) → Edit(file=X, old_string⊇A) within WINDOW seconds.
Appends correction entries to a persistent JSONL outside the per-session dir.

Never blocks — observation only.
"""

import json
import fcntl
import os
import time
from pathlib import Path

CORRECTIONS_LOG = os.getenv(
    "WALTER_CORRECTIONS_LOG", "/var/log/walter/corrections/corrections.jsonl"
)
# Rolling state: recent edits per file (kept in a small file, not memory,
# because each hook invocation is a fresh process)
_STATE_FILE = "/var/log/walter/.edit_state.json"

# How many seconds between edits counts as a "correction"
WINDOW_SECONDS = int(os.getenv("WALTER_CORRECTION_WINDOW", "120"))

# Max recent edits to track per file
_MAX_PER_FILE = 3


def _load_state() -> dict:
    """Load recent edit state. Format: {file_path: [{new_string_head, epoch}, ...]}"""
    try:
        with open(_STATE_FILE, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _save_state(state: dict):
    try:
        Path(_STATE_FILE).parent.mkdir(parents=True, exist_ok=True)
        with open(_STATE_FILE, "w") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            json.dump(state, f)
            fcntl.flock(f, fcntl.LOCK_UN)
    except OSError:
        pass


def _log_correction(entry: dict):
    try:
        Path(CORRECTIONS_LOG).parent.mkdir(parents=True, exist_ok=True)
        with open(CORRECTIONS_LOG, "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
            f.flush()
            fcntl.flock(f, fcntl.LOCK_UN)
    except OSError:
        pass


def check_edit(tool_input: dict, session_id: str = ""):
    """Called on every Edit tool invocation. Detects and logs corrections."""
    file_path = tool_input.get("file_path", "")
    old_string = tool_input.get("old_string", "")
    new_string = tool_input.get("new_string", "")

    if not file_path or not old_string:
        # First write or no old_string — just record and return
        _record_edit(file_path, new_string)
        return

    now = time.time()
    state = _load_state()
    recent = state.get(file_path, [])

    # Check if old_string contains text from a recent new_string
    for prev in recent:
        age = now - prev["epoch"]
        if age > WINDOW_SECONDS:
            continue

        prev_text = prev["new_string_head"]
        # Match: the old_string we're replacing contains what we recently wrote
        # Use a meaningful overlap (at least 20 chars or full match for short strings)
        min_overlap = min(20, len(prev_text))
        if len(prev_text) >= min_overlap and prev_text in old_string:
            _log_correction({
                "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "epoch": now,
                "session_id": session_id,
                "project": os.getenv("WALTER_PROJECT_NAME", ""),
                "file": file_path,
                "gap_seconds": round(age, 1),
                "original_wrote": prev_text[:300],
                "corrected_from": old_string[:300],
                "corrected_to": new_string[:300],
            })
            break  # One correction per edit is enough

    # Record this edit for future comparison
    _record_edit(file_path, new_string)


def _record_edit(file_path: str, new_string: str):
    """Store this edit's new_string for future correction detection."""
    if not file_path or not new_string:
        return

    state = _load_state()
    now = time.time()

    # Keep only recent entries, prune old ones
    recent = [
        e for e in state.get(file_path, [])
        if now - e["epoch"] < WINDOW_SECONDS
    ]

    # Store first 500 chars of new_string (enough for matching, not too heavy)
    recent.append({
        "new_string_head": new_string[:500],
        "epoch": now,
    })

    # Cap per file
    state[file_path] = recent[-_MAX_PER_FILE:]

    # Prune files with only stale entries
    state = {
        fp: entries for fp, entries in state.items()
        if any(now - e["epoch"] < WINDOW_SECONDS for e in entries)
    }

    _save_state(state)
