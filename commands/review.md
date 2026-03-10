---
description: "Multi-phase code review: 5 agents → Codex → 2 final agents on specified files"
allowed-tools: Bash, Read, Glob, Grep
---

# Multi-Phase Code Review

Run the full review pipeline (7 agents + Codex) on specified files.

## Input

`$ARGUMENTS` — space-separated file paths to review. Examples:
- `src/main.py`
- `src/main.py src/utils.py hooks/guard.sh`
- `src/` (directory — will be expanded to all files inside)

## Instructions

### Step 1: Resolve file list

If any argument is a directory, expand it to all source files within it (glob recursively, skip `.git/`, `node_modules/`, `__pycache__/`).

Verify each file exists. If a file doesn't exist, warn and skip it.

Build the final comma-separated file list string.

### Step 2: Launch review-executor

```bash
WALTER_REVIEW_FILES="<comma-separated list>" \
WALTER_PLAN_FILE="${WALTER_PLAN_FILE:-}" \
WALTER_PLAN_GOAL="Interactive code review" \
  /opt/review/review-executor.sh
```

Do NOT use `exec` — the review runs as a subprocess so control returns to you after.

### Step 3: Report

After review-executor completes, read the pipeline summary from its output and present it to the user.

If review-executor exits non-zero, report the error.

User input: $ARGUMENTS
