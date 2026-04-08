---
description: "Use after planning to run current phase. Trigger: 'execute', 'выполняй', 'run the plan', 'запускай'"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# SDD: Execute Phase

You are executing the plans for the current SDD phase.

## Step 1: Load Context

1. Read `.planning/STATE.md` for current phase and plan list
2. Read each plan file listed in STATE.md
3. Determine execution waves:
   - Check each plan for `depends:` frontmatter
   - Plans with no dependencies → Wave 1 (parallel)
   - Plans depending on Wave 1 → Wave 2, etc.
   - Default (no depends declared): sequential order

## Step 2: Execute Wave by Wave

For each wave, process every plan in that wave. Plans within the same wave can run in parallel; tasks within a single plan run sequentially.

**Parse each plan file before execution:**
1. Read the plan file
2. Extract the **preamble** — everything before the first `### Task` header, capped at 200 lines
3. Extract the `## Validation Commands` section
4. Parse all `### Task N: {title}` sections

**Execute each `### Task N:` in a separate plan-executor agent** (one agent per task, not one agent per plan). Zero shared state between tasks — each agent only sees preamble + its own task + validation commands:

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
- Check the result for blockers or failures
- If a task failed, **stop execution of this plan** and report to the user — do NOT proceed to the next task in the same plan
- If successful, continue to the next task in the same plan

Wait for all plans in a wave to complete before starting the next wave.

**Why per-task agents**: prevents context bleed between tasks, keeps each agent's window focused, makes failures resumable from any task, and matches the isolation contract documented under "Task isolation" in plans.

## Step 3: Verify Delivery

After all waves complete, spawn qa-validator:

```
Agent(subagent_type="qa-validator", prompt="Verify that all plans in .planning/phases/phase-{N}-*-PLAN.md have been executed correctly. Compare:
1. All [ ] items are now [x]
2. Validation commands pass
3. Requirements from .planning/REQUIREMENTS.md are met
4. git diff shows expected changes
Report pass/fail for each requirement.")
```

## Step 4: Handle Failures

If qa-validator reports failures, spawn sdd-debugger:

```
Agent(subagent_type="sdd-debugger", prompt="Diagnose verification failures for Phase {N}. QA report: {qa output}. Create a fix plan at .planning/phases/phase-{N}-FIX-PLAN.md")
```

Then execute the fix plan **using the same per-task pattern as Step 2**: parse preamble + `### Task N:` sections + `## Validation Commands`, then spawn one plan-executor agent per task sequentially. Do NOT pass the whole FIX-PLAN.md to a single agent.

Re-verify after fix. If still failing after 2 fix cycles, stop and report to user.

## Step 5: Document Results

After verification passes (or after fix cycles complete), create a results summary:

Write `.planning/phases/phase-{N}-RESULTS.md`:

```markdown
# Phase {N} Results: {Phase Name}

## Summary
{2-3 sentences: what was built/changed and why}

## Changes Made
{List of key files modified/created with brief descriptions}

## Decisions During Execution
{Any deviations from plan, blockers encountered, and how they were resolved}

## Validation Status
{Pass/fail summary from qa-validator}
```

## Step 5.5: Record Delta Specs

After documenting results, check if any requirements changed during this phase:
- New requirements discovered during implementation
- Requirements modified based on implementation reality
- Requirements removed as infeasible or out of scope

If changes exist, append to `.planning/REQUIREMENTS-CHANGELOG.md`:

```markdown
## Phase {N}: {Phase Name} ({ISO date})

### ADDED
- {new requirement} — Reason: {why added}

### MODIFIED
- {original requirement} → {updated requirement} — Reason: {what changed}

### REMOVED
- {removed requirement} — Reason: {why removed}
```

If `.planning/REQUIREMENTS-CHANGELOG.md` doesn't exist, create it with a header first.
If no requirement changes occurred, skip this step.

## Step 6: Capture Lessons

If any of the following occurred during this phase, capture lessons:
- Fix cycles were needed (sdd-debugger was invoked)
- Plan deviations were flagged by plan-executor
- qa-validator found issues
- Unexpected blockers were encountered

For each, append to `tasks/lessons.md` following the format in that file:
1. What went wrong or was unexpected
2. Root cause
3. Preventive rule for future phases
4. Scope (this phase or general)

Skip this step if execution was clean with no issues.

## Step 7: Update State

Update `.planning/STATE.md`:
- State: VERIFYING (after execution), PHASE_COMPLETE (after verification passes), or FIX (if debugging)
- Updated: {ISO timestamp}

If verification passed, suggest: `/sdd:verify-work` for final UAT with user.
If issues remain, present the diagnostic summary.

User input: $ARGUMENTS
