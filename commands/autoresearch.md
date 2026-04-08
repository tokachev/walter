---
description: "Autonomous research loop: iteratively improves a target file using AI experiments with eval-driven feedback. Use when user says 'autoresearch', 'автоисследование', 'optimize in a loop', 'research loop', 'iterative improvement'"
allowed-tools: Bash, Read, Glob, Grep, Write, AskUserQuestion
---

# Autoresearch — Iterative Improvement Loop

Autonomous loop: each iteration a fresh `claude -p` agent proposes one change to a target file,
runs an eval, and keeps or discards the change based on the metric.

## Step 1: Parse Input

`$ARGUMENTS` contains the task description. Extract:
- **Target file path** — a file path mentioned explicitly (e.g. `src/foo.py`, `queries/report.sql`)
- **Optimization goal** — what to improve (performance, pass rate, score, etc.)

If no file path is found in `$ARGUMENTS`, use AskUserQuestion to ask for it.

Validate the target file exists by reading it. If it doesn't exist, stop and report.

## Step 2: Explore Target

Read the target file in full.

Glob the surrounding directory to understand adjacent files and context.
Identify: what does this file do? What metrics are meaningful to optimize?
Keep this as internal context for Step 3.

## Step 3: Generate Eval Script

Based on the target file and optimization goal, write an eval script to
`/workspace/sandbox/autoresearch/eval.sh`:

```bash
mkdir -p /workspace/sandbox/autoresearch
```

**Eval contract (mandatory):**
- Last line of stdout MUST be a single number (integer or float)
- Add a comment at the top: `# Metric: <what it measures> (lower|higher is better)`
- The script should be self-contained and reproducible

Reference examples in `/opt/autoresearch/examples/` for patterns:
- `sql-time.sh` — SQL execution time (lower = better)
- `pytest-score.sh` — pytest pass rate 0-100 (higher = better)
- `generic-metric.sh` — wraps any command, extracts last numeric line

Choose the closest example as a template, or write from scratch if none fit.

## Step 4: Approval

Read back the generated `/workspace/sandbox/autoresearch/eval.sh` and show it to the user.

Use AskUserQuestion:

```
Eval script generated. Review before launching:

<contents of eval.sh>

Options:
1. Looks good, launch
2. Need changes (describe what to fix)
3. Cancel
```

- If "Looks good" → proceed to Step 5
- If "Need changes" → apply the feedback and regenerate, then loop back to this step
- If "Cancel" → stop

## Step 5: Launch Runner

Derive a tag from the task description:
- lowercase, spaces → hyphens, strip non-alphanumeric, max 30 chars
- Example: "optimize SQL query runtime" → `optimize-sql-query-runtime`

Run:

```bash
bash /opt/autoresearch/autoresearch.sh \
  --target-file <absolute-path-to-target-file> \
  --eval-command "bash /workspace/sandbox/autoresearch/eval.sh" \
  --tag <tag>
```

Tell the user:
> Autoresearch запущен. Каждая итерация модифицирует `<target-file>` и проверяет метрику.
> Ctrl+C для остановки. Результаты в `results.tsv`.

User input: $ARGUMENTS
