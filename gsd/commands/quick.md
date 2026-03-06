---
description: "Fast path: create plan and execute immediately, skipping research and validation"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# GSD: Quick

Fast-path execution: plan → execute → report. No research, no checker, no multi-phase ceremony.

## Step 1: Understand the Task

Read $ARGUMENTS as the task description. If `.planning/` exists, read STATE.md for context.

## Step 2: Create Plan

Create a plan directly at `.planning/phases/quick-PLAN.md`:
- Analyze the codebase yourself (quick scan of relevant files)
- Write a plan with `### Task N:` headers and `- [ ]` items
- Include `## Validation Commands`
- Keep it tight: 1-5 tasks max

If `.planning/` doesn't exist, create minimal structure:
```
.planning/
  STATE.md
  phases/
    quick-PLAN.md
```

## Step 3: Execute

Spawn plan-executor:

```
Agent(subagent_type="plan-executor", prompt="Execute the plan at .planning/phases/quick-PLAN.md. Follow each task. Mark items [x] when done. Run validation commands.")
```

## Step 4: Report

After execution:
- Summarize what was done
- Show key changes
- Report any validation failures

Update `.planning/STATE.md` if it exists.

User input: $ARGUMENTS
