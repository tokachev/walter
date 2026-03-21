---
description: "Present deliverables to user for UAT acceptance and handle issues"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# SDD: Verify Work

You are presenting the completed phase deliverables to the user for acceptance.

## Step 1: Load Context

1. Read `.planning/STATE.md` for current phase
2. Read `.planning/REQUIREMENTS.md`
3. Read all plan files for this phase
4. Run `git diff main` (or appropriate base) to see all changes

## Step 2: Present Deliverables (3D Verification)

Show the user a structured summary across three dimensions:

### Completeness
- List each requirement and its status (done/partial/missing)
- Count: {N}/{total} requirements fully met
- Any gaps flagged by qa-validator

### Correctness
- Key code decisions and whether they match spec intent
- Edge cases covered vs. uncovered
- Show relevant code snippets for critical logic

### Coherence
- Design consistency assessment
- Any deviations from original plan (and justification)
- Scope verification: only planned changes made?

### Demo Points
- Highlight the most impactful changes
- Key files changed (grouped by purpose)
- If there are runnable demos, suggest commands

## Step 3: Collect Feedback

Ask the user:
- Does this meet your expectations?
- Any issues to address?
- Ready to move to next phase?

## Step 4: Handle Issues

If user reports issues, spawn sdd-debugger:

```
Agent(subagent_type="sdd-debugger", prompt="User reported issues during UAT for Phase {N}: {user feedback}. Diagnose and create fix plan.")
```

Then execute the fix plan and re-present.

## Step 5: Complete Phase

If accepted, update `.planning/STATE.md`:
- State: PHASE_COMPLETE
- Updated: {ISO timestamp}
- Notes: Phase {N} accepted by user

Suggest next step:
- If more phases in ROADMAP.md: `/sdd:discuss-phase` for next phase
- If last phase: "Project complete!"

User input: $ARGUMENTS
