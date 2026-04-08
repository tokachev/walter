---
description: "Use for small tasks that don't need full SDD. Trigger: 'quick', 'быстро сделай', 'just do it', 'сделай по-быстрому'"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# SDD: Quick

Fast-path execution: compact dual-model research → compact synthesized plan → execute → report.

## Step 1: Understand the Task

Read `$ARGUMENTS` as the task description. If `.planning/` exists, read `STATE.md` for context and any current phase notes that constrain the work.

## Step 2: Compact Dual Research

If `.planning/` does not exist, create minimal structure:
```
.planning/
  STATE.md
  phases/
```

Launch a focused Claude scan in the background:

```
Agent(subagent_type="codebase-researcher", run_in_background=true, prompt="Do a compact investigation for this quick task: {task description from $ARGUMENTS}. Focus only on files, patterns, dependencies, and validation paths directly needed for implementation. Write findings to .claude/research/quick-research-claude.md")
```

Run Codex in parallel — execute the following command using the Bash tool. First verify codex is available with `command -v codex`. If codex is not found, skip to merge and note degraded mode:

```bash
mkdir -p .claude/research
codex exec -s danger-full-access <<'CODEX_EOF' 2>&1 | tee .claude/research/quick-research-codex.md
Do a compact investigation for this quick task:
{task description from $ARGUMENTS}

Focus only on:
- directly relevant files and modules
- existing implementation patterns to follow
- likely integration points and risks
- the shortest meaningful validation path

Output structured markdown with concrete file references.
CODEX_EOF
```

After both complete, write `.claude/research/quick-research.md`:
- Shared findings
- Claude-only insights
- Codex-only insights
- Any contradictions that affect execution

If Codex is unavailable, continue with Claude-only research but say so explicitly in the merged file and final report.

## Step 3: Create the Quick Plan

Create the plan at `.planning/phases/quick-PLAN.md` via the shared `plan-coordinator` flow:

```
Agent(subagent_type="plan-coordinator", prompt="
PHASE_NUMBER: quick
PHASE_DESCRIPTION: {task description from $ARGUMENTS}
OUTPUT_PATH: .planning/phases/quick-PLAN.md

REQUIREMENTS:
- Solve the task described in $ARGUMENTS.
- Keep the plan compact: 1-5 tasks max.
- Preserve existing behavior outside the requested scope.

DECISIONS:
{relevant constraints or notes from STATE.md if present}

RESEARCH:
{paste key findings from .claude/research/quick-research.md}
")
```

After the coordinator finishes, verify `.planning/phases/quick-PLAN.md` exists and is plan-executor compatible.

## Step 4: Execute

Parse `.planning/phases/quick-PLAN.md` before execution:
1. Extract the **preamble** — everything before the first `### Task` header, capped at 200 lines
2. Extract the `## Validation Commands` section
3. Parse all `### Task N: {title}` sections

**Execute each `### Task N:` in a separate plan-executor agent** (one agent per task, not one agent for the whole plan). Tasks run sequentially:

```
Agent(subagent_type="plan-executor", prompt="
You are executing a single task from a larger plan.

## Plan Context
{preamble}

## Your Task
{full content of ### Task N, including all checklist items}

## Validation Commands
{validation commands section}

Execute this task precisely. Mark items as [x] when done. Run validation commands after completion.
If blocked, report the blocker — do not guess or skip.
")
```

After each agent returns:
- If the task failed, stop and report to the user — do NOT proceed to the next task
- If successful, continue to the next task

## Step 5: Report

After execution:
- Summarize what was done
- Show key changes
- Report any validation failures
- Mention whether the quick plan was synthesized from both Claude + Codex or fell back to Claude-only

Update `.planning/STATE.md` if it exists.

User input: $ARGUMENTS
