---
description: "Iterative peer review via Codex: review → fix → re-review until convergence"
allowed-tools: Bash, Read, Glob, Grep, Edit, Agent
---

# Peer Review — Iterative Codex Loop

Codex reviews code, you evaluate findings and fix confirmed issues, Codex re-reviews your fixes — repeat until Codex finds nothing or stalemate.

## Step 1: Resolve Files

`$ARGUMENTS` — path(s) to file or directory. Examples: `src/main.py`, `src/utils/`, `src/main.py src/config.py`

If a directory — glob recursively for source files (skip `.git/`, `node_modules/`, `__pycache__/`, `sandbox/`).
Verify each file exists. Build a newline-separated `FILE_LIST` string.

## Step 2: Iterative Review Loop

Run up to **5 iterations**. Each iteration is a single Agent call to keep context clean.

Track these across iterations:
- `dismissed_list` — findings dismissed as false positives (accumulated, passed to next iteration)
- `iteration` counter

### Iteration Agent Prompt

For each iteration, spawn one Agent with this prompt structure (adapt per iteration):

```
You are a senior engineer running one iteration of a Codex peer review.

## Your Task

1. Dispatch Codex to review the code
2. Evaluate Codex's findings
3. Fix confirmed issues
4. Return a structured summary

## Files to Review

<FILE_LIST here>

## Iteration: <N>

<if iteration 1>
## Codex Dispatch

Run this command to get Codex's review:

    codex exec -s danger-full-access <<'CODEX_PROMPT' 2>&1
    Review the following files for bugs, logic errors, security vulnerabilities,
    race conditions, error handling gaps, and design problems. Be specific —
    reference exact file names and line numbers. For each issue: what is wrong,
    why it matters, and how to fix it.

    Files to review:
    <FILE_LIST, each line prefixed with "- ">
    CODEX_PROMPT
</if>

<if iteration 2+>
## Context from Previous Iterations

These findings were already dismissed as false positives in prior iterations.
Do NOT re-fix them unless Codex provides new evidence.

<DISMISSED_LIST here>

## Codex Dispatch

Run this command. Pass the git diff so Codex focuses on recent changes:

    DIFF=$(git diff)
    codex exec -s danger-full-access <<CODEX_PROMPT 2>&1
    Review the following code changes for bugs, logic errors, security vulnerabilities,
    race conditions, error handling gaps, and design problems. Be specific —
    reference exact file names and line numbers.

    Focus on the changes shown in the diff below. You may read the full files
    for context but your findings should be about the changed code.

    Files: <FILE_LIST>

    Diff:
    $DIFF
    CODEX_PROMPT
</if>

## Evaluate Codex Output

Read the Codex output. For each finding:
- **Confirmed**: the issue is real — read the file, verify, fix it with the Edit tool
- **False positive**: Codex misread the code or flagged intentional behavior — dismiss with a reason
- **Deferred**: real issue but out of scope — note it

Fix confirmed issues minimally. No refactoring beyond what the issue requires.
Do NOT run git add or git commit.

## Return Format

End your response with EXACTLY this structured block (parseable by the caller):

    <<<REVIEW_RESULT>>>
    ITERATION: <N>
    CODEX_FINDINGS: <total count>
    FIXED: <count>
    DISMISSED: <count>
    DEFERRED: <count>
    STATUS: <one of: CONVERGED | FINDINGS_FIXED | STALEMATE | ERROR>
    DISMISSED_LIST:
    - <finding summary> — <reason for dismissal>
    <<<END_REVIEW_RESULT>>>

STATUS rules:
- CONVERGED: Codex produced no findings (or empty/error output with no actionable content)
- FINDINGS_FIXED: you fixed at least one issue — Codex needs to re-verify
- STALEMATE: all Codex findings are repeats of previously dismissed items — no code changed
- ERROR: Codex failed to run or produced unusable output
```

### Loop Control

After each Agent returns:

1. Parse the `<<<REVIEW_RESULT>>>` block from the agent's response
2. Extract `STATUS`:
   - **CONVERGED** → exit loop. Codex found nothing — reviews agree.
   - **FINDINGS_FIXED** → continue to next iteration. Codex needs to verify fixes.
   - **STALEMATE** → exit loop. Models disagree, no progress possible.
   - **ERROR** → exit loop with warning.
3. Extract `DISMISSED_LIST` and append to accumulated dismissed list for next iteration
4. If iteration 5 reached without convergence → exit loop, report as MAX_ITERATIONS

## Step 3: Report

After the loop, output:

```
## Peer Review Results (<N> iterations, <STATUS>)

### Fixed Issues
- <issue> — <file:line> (iteration <N>)
...

### Dismissed (False Positives)
- <issue> — <reason>
...

### Deferred
- <issue> — <reason>
...

### Remaining Disagreements
(only if STALEMATE — list what Codex insists on and why you disagree)
```

Do NOT commit changes. Leave everything in the working tree for the user.

User input: $ARGUMENTS
