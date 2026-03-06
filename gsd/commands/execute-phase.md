---
description: "Execute plans for current phase with wave-based parallelism and verification"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# GSD: Execute Phase

You are executing the plans for the current GSD phase.

## Step 1: Load Context

1. Read `.planning/STATE.md` for current phase and plan list
2. Read each plan file listed in STATE.md
3. Determine execution waves:
   - Check each plan for `depends:` frontmatter
   - Plans with no dependencies → Wave 1 (parallel)
   - Plans depending on Wave 1 → Wave 2, etc.
   - Default (no depends declared): sequential order

## Step 2: Execute Wave by Wave

For each wave, spawn plan-executor agents:

```
Agent(subagent_type="plan-executor", prompt="Execute the plan at .planning/phases/{plan-file}. Follow each task sequentially. Mark items as [x] when done. Run validation commands after each task.")
```

If running multiple plans in a wave, spawn them in parallel.

Wait for all agents in a wave to complete before starting the next wave.

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

If qa-validator reports failures, spawn gsd-debugger:

```
Agent(subagent_type="gsd-debugger", prompt="Diagnose verification failures for Phase {N}. QA report: {qa output}. Create a fix plan at .planning/phases/phase-{N}-FIX-PLAN.md")
```

Then execute the fix plan:

```
Agent(subagent_type="plan-executor", prompt="Execute the fix plan at .planning/phases/phase-{N}-FIX-PLAN.md")
```

Re-verify after fix. If still failing after 2 fix cycles, stop and report to user.

## Step 5: Update State

Update `.planning/STATE.md`:
- State: VERIFYING (after execution), PHASE_COMPLETE (after verification passes), or FIX (if debugging)
- Updated: {ISO timestamp}

If verification passed, suggest: `/gsd:verify-work` for final UAT with user.
If issues remain, present the diagnostic summary.

User input: $ARGUMENTS
