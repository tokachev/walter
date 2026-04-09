---
description: "Execute or resume autopilot plan, starting from the first incomplete task. Trigger: 'execute', 'resume', 'продолжи', 'выполни план'"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# SDD: Execute (Resume Autopilot Plan)

Executes `.planning/autopilot-PLAN.md` starting from the first task that still has unchecked `- [ ]` items. Each remaining task runs in a separate `plan-executor` agent. After each successful task, the parent process marks progress in the plan file and bumps `STATE.md`.

This command is for **resuming** an autopilot plan that was partially executed (or never started). Use `/sdd:autopilot` to plan from scratch, then `/sdd:execute` to run / re-run the resulting `autopilot-PLAN.md`.

## Step 1: Load and Validate

1. Read `.planning/STATE.md`. If missing → report `No SDD project initialized. Run /sdd:autopilot first.` and stop.
2. Read `.planning/autopilot-PLAN.md`. If missing → report `No autopilot plan found at .planning/autopilot-PLAN.md. Run /sdd:autopilot first.` and stop.
3. Parse the plan file:
   - **Preamble** — everything before the first `### Task ` header, capped at 200 lines
   - **Validation Commands** — content of the `## Validation Commands` section
   - **Tasks** — every `### Task N: {title}` section. A task's content runs from its header to the next `### Task ` header (or to `---` / EOF if it is the last task)
4. Determine total task count = number of `### Task ` headers.

## Step 2: Build the Incomplete Task List

Walk tasks in order. For each task section, classify it:
- If the section body contains **any** line starting with `- [ ]` → task is **incomplete**, add it to the work list
- If the section body has **zero** `- [ ]` lines (only `- [x]` and/or `- [WAIT]`) → task is **done**, skip it entirely

Note: tasks are skipped individually, not by position. A done task between two incomplete tasks (e.g. Task 3 between Task 2 and Task 4) is **not** re-executed.

If the work list is empty → report `All tasks already complete. Plan: .planning/autopilot-PLAN.md` and stop.

Otherwise let `done = total - len(work_list)` and `remaining = len(work_list)`. Announce:

```
Resuming autopilot plan from Task {first_incomplete_N}: {title}
Done: {done}/{total} | Remaining: {remaining}
```

## Step 3: Execute Remaining Tasks Sequentially

Update `.planning/STATE.md`:
- `State: EXECUTING`
- `Updated:` to current ISO timestamp

For each task in the **work list from Step 2**, in order, spawn one `plan-executor` agent per task:

```
Agent(subagent_type="plan-executor", prompt="
You are executing a single task from a larger plan.

## Plan Context
{preamble}

## Your Task
{full content of ### Task N, including all checklist items}

## Validation Commands
{validation commands section}

Execute this task precisely. Run validation commands after completion.
Do not modify .planning/autopilot-PLAN.md — the parent process will mark progress.
If blocked, report the blocker — do not guess or skip.
")
```

After each agent completes:
- Check the agent's result for blockers or failures
- If a task failed, stop execution and report to the user — do NOT proceed to the next task and do NOT mark the task as done
- If successful, mark progress in the plan file:
  1. Read `.planning/autopilot-PLAN.md`
  2. Locate the section `### Task {N}: {title}` — its content runs from the header to the next `### Task ` header (or to `---` / EOF if it is the last task)
  3. In that section only, replace every `- [ ]` with `- [x]`. Leave any `- [WAIT]` items untouched
  4. Use a single Edit call with the full task section as `old_string` and the updated section as `new_string` (the section is unique because of its task number, so the Edit will not collide)
  5. Update `.planning/STATE.md`: bump the `- Progress: {done}/{total} tasks complete` line and refresh `Updated:` to the current ISO timestamp
- Continue to the next task

## Step 4: Report

After all remaining tasks finish (or after a failure stops execution):

**On success:**
```
Executed {executed_count} tasks successfully.
{total}/{total} complete.

Next: /sdd:verify-work for UAT, or /sdd:archive when done.
```

**On failure mid-execution:**
```
Stopped at Task {N}: {title}
Reason: {blocker or failure summary}
Done: {done}/{total} | Remaining: {remaining}

Fix the issue, then run /sdd:execute again to resume from Task {N}.
```

User input: $ARGUMENTS
