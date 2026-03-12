---
description: "Multi-phase code review: 5 agents → evaluate+fix → 2 final agents → verdict"
allowed-tools: Bash, Read, Glob, Grep, Agent, Edit, Write
---

# Multi-Phase Code Review

Run the full review pipeline (7 agents) on specified files using Agent tool (works inside interactive sessions).

## Input

`$ARGUMENTS` — space-separated file paths to review. Examples:
- `src/main.py`
- `src/main.py src/utils.py hooks/guard.sh`
- `src/` (directory — will be expanded to all files inside)

## Instructions

### Step 1: Resolve file list

If any argument is a directory, expand it to all source files within it (glob recursively, skip `.git/`, `node_modules/`, `__pycache__/`).

Verify each file exists. If a file doesn't exist, warn and skip it.

Build the final newline-separated file list string called `FILE_LIST`.

### Step 2: Prepare findings directory

```bash
rm -rf /tmp/walter-review
mkdir -p /tmp/walter-review
```

### Step 3: Phase 1 — First Review (5 agents in parallel)

Spawn ALL 5 agents in a SINGLE message (parallel execution) using the Agent tool with `subagent_type: "code-review-strict"`. Each agent MUST:
- Read every file in FILE_LIST
- Write findings to the specified output path
- Follow the review criteria below

**Agent 1 — Quality** (output: `/tmp/walter-review/quality.md`)
Focus: bugs, security vulnerabilities, race conditions, error handling gaps, resource leaks.
Classify as CRITICAL / MAJOR / MINOR.

**Agent 2 — Implementation** (output: `/tmp/walter-review/implementation.md`)
Focus: does the code actually work? Are there broken implementations, disconnected code, missing wiring?
Do NOT assess style — only whether the code functions correctly.

**Agent 3 — Testing** (output: `/tmp/walter-review/testing.md`)
Focus: missing test coverage, missing edge cases, untested error paths, flaky test patterns.
Suggest concrete test cases for each gap.

**Agent 4 — Simplification** (output: `/tmp/walter-review/simplification.md`)
Focus: over-engineering, dead code, copy-paste duplication, unnecessary complexity.
Only flag things that actively hurt readability or maintainability.

**Agent 5 — Documentation** (output: `/tmp/walter-review/docs.md`)
Focus: missing docstrings, outdated/misleading comments, undocumented config options, README gaps.

For each agent prompt, include the full FILE_LIST so the agent knows which files to read.

### Step 4: Evaluate Phase 1 findings

Read all 5 findings files from `/tmp/walter-review/`. For each issue:
- **Confirmed**: real, reproducible, worth fixing now → fix it
- **False positive**: agent misunderstood the code → dismiss
- **Deferred**: real but out of scope → note it

Fix all confirmed issues. Priority: quality > implementation > testing > simplification > docs.

Do NOT commit. Leave changes in the working tree for the user to review and commit manually.

### Step 5: Phase 3 — Final Review (2 agents in parallel)

Spawn 2 agents in a SINGLE message using `subagent_type: "code-review-strict"`:

**Agent 6 — Final Quality** (output: `/tmp/walter-review/final-quality.md`)
STRICT threshold: ONLY flag issues that would cause production failures, data loss, or security breaches. Do NOT flag style, edge cases, missing tests, or docs.

**Agent 7 — Final Implementation** (output: `/tmp/walter-review/final-impl.md`)
STRICT threshold: ONLY flag completely missing implementations, broken code that will not work, or disconnected code that is never called.

### Step 6: Final evaluation

Read both final findings files. Fix any critical issues found. Do NOT commit — leave in working tree.

### Step 7: Report

Present a summary:

```
## Review Complete

### Phase 1 (5 agents)
- Fixed: X issues
- Dismissed: Y false positives
- Deferred: Z issues

### Final Review (2 agents)
- Critical issues: X (fixed/none)

### Verdict: APPROVED / BLOCKED
```

APPROVED = no unresolved critical issues. BLOCKED = critical issues remain unfixed.

User input: $ARGUMENTS
