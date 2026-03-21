---
description: "Archive completed phases or entire project with full audit trail"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# SDD: Archive

Archive completed phases (or the entire project) to preserve a full audit trail and keep `.planning/phases/` clean.

## Step 1: Determine Scope

1. Read `.planning/STATE.md` for current state and phase info
2. Read `.planning/ROADMAP.md` for phase names
3. Determine what to archive:
   - If $ARGUMENTS contains "project" → archive entire project (all completed phases)
   - If $ARGUMENTS contains a phase number (e.g., "3") → archive that specific phase
   - Default (no arguments): archive all phases in PHASE_COMPLETE state

## Step 2: Validate Readiness

For each phase to be archived, verify:
- Phase has reached PHASE_COMPLETE state (check RESULTS.md existence)
- All plan items are marked `[x]` (scan plan files for unchecked items)
- `.planning/phases/phase-{N}-RESULTS.md` exists

If any phase fails validation, report which phases are not ready and why. Continue with the phases that pass.

## Step 3: Check for Unsynced Delta Specs

Read `.planning/REQUIREMENTS-CHANGELOG.md` (if it exists):
- If there are unsynced phase deltas for the phases being archived, warn the user:
  > "Phase {N} has unsynced requirement changes. Run `/sdd:sync-specs` first to merge them into REQUIREMENTS.md, or they'll be archived as-is."
- Wait for user confirmation before proceeding.

## Step 4: Create Archive

For each phase being archived:

1. Create directory: `.planning/archive/phase-{N}-{YYYY-MM-DD}/`
2. Move all phase artifacts into the archive directory:
   - `phase-{N}-CONTEXT.md`
   - `phase-{N}-EXPLORE.md`
   - `phase-{N}-PLAN.md` (and any numbered variants like `phase-{N}-1-PLAN.md`)
   - `phase-{N}-PLAN-claude.md`, `phase-{N}-PLAN-codex.md` (if they exist)
   - `phase-{N}-RESULTS.md`
   - `phase-{N}-FIX-PLAN.md` (if it exists)
   - Any related research files from `.claude/research/phase-{N}-*`
3. Create `.planning/archive/phase-{N}-{YYYY-MM-DD}/archive-summary.md`:

```markdown
# Archive: Phase {N} — {Phase Name}

- Archived: {ISO timestamp}
- Original State: PHASE_COMPLETE

## What Was Delivered
{Summary from RESULTS.md}

## Key Decisions
{From CONTEXT.md — approach, key decisions}

## Files Changed
{From RESULTS.md — list of key files}

## Lessons Captured
{Any lessons from this phase in tasks/lessons.md, or "None"}

## Delta Specs
{Summary of ADDED/MODIFIED/REMOVED requirements from this phase, or "None"}
```

## Step 5: Update State

Update `.planning/STATE.md`:
- Remove archived phases from the plans list
- Add note: `Archived phase(s) {N} on {ISO timestamp}`
- If archiving entire project (all phases complete): State → ARCHIVED

## Step 6: Report

Present summary:
- Phases archived: {list}
- Archive locations: `.planning/archive/phase-{N}-{date}/`
- Total artifacts archived: {count}

Suggest next steps:
- If more phases remain: `/sdd:discuss-phase` for the next phase
- If project archived: "Project fully archived. Start a new project with `/sdd:new-project`"

User input: $ARGUMENTS
