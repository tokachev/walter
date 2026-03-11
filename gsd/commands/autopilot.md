---
description: "Interactive planning across all phases, then export a single self-contained plan for autonomous execution"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# GSD: Autopilot

Full interactive GSD planning (with discussions and clarifications), but instead of executing phase-by-phase, all phases are planned upfront and exported into one self-contained plan file for autonomous execution in a fresh Walter session.

## Step 1: Project Setup

Check if `.planning/` already exists:
- **If yes**: Read `STATE.md`, `PROJECT.md`, `REQUIREMENTS.md`, `ROADMAP.md` to load existing context. Skip to Step 3.
- **If no**: Run the full new-project flow (Step 2).

## Step 2: Interactive Brief (only if no `.planning/`)

Ask the user these questions (skip any answered in $ARGUMENTS):
1. **What are we building?** (one paragraph)
2. **What's the desired outcome?** (what does "done" look like)
3. **Any constraints?** (tech stack, timeline, compatibility requirements)
4. **Is there existing code to work with?** (if yes, research it)

If working with existing code, spawn codebase-researcher:

```
Agent(subagent_type="codebase-researcher", prompt="Research the codebase for: project structure, tech stack, key patterns. Write findings to .claude/research/gsd-codebase-overview.md")
```

Create `.planning/` structure: `PROJECT.md`, `REQUIREMENTS.md`, `ROADMAP.md`, `STATE.md`.

Present the roadmap with all phases to the user for confirmation before proceeding.

## Step 3: Plan Each Phase Interactively

For each phase in `ROADMAP.md`, do the following **interactively** (do NOT skip discussions):

### 3a. Discuss Phase

Present the phase scope and discuss with the user:
- **Approach**: How should we implement this? What patterns to use?
- **Decisions**: Any technical choices to make?
- **Risks**: What could go wrong? Edge cases?
- **Dependencies**: External services, APIs, data sources?

Capture decisions in `.planning/phases/phase-{N}-CONTEXT.md`.

### 3b. Research (if needed)

If the phase touches existing code, spawn codebase-researcher:

```
Agent(subagent_type="codebase-researcher", prompt="Research areas of the codebase relevant to Phase {N}: {phase description}. Write findings to .claude/research/phase-{N}-research.md")
```

### 3c. Create Phase Plan

Spawn walter-planner:

```
Agent(subagent_type="walter-planner", prompt="Create execution plan for Phase {N}. Context: {requirements, decisions, research}. Write to .planning/phases/phase-{N}-PLAN.md. Use ### Task N: headers with - [ ] items. Include ## Validation Commands. Max 10 tasks, 3-7 items per task.")
```

### 3d. Review Plan with User

Present the created plan to the user. Ask:
- Does this plan look right?
- Any tasks to add/remove/modify?

Apply any changes before moving to the next phase.

**Repeat 3a-3d for every phase in the roadmap.**

## Step 4: Export Combined Plan

After ALL phases are planned:

1. Read all `.planning/phases/phase-*-PLAN.md` files in order.
2. Create a single self-contained plan file at `.planning/autopilot-PLAN.md`:

```markdown
# Autopilot Plan: {Project Name}

## Project Context
{Summary from PROJECT.md — goal, constraints, tech stack}

## Requirements
{From REQUIREMENTS.md — must have, should have}

## Codebase Notes
{Key findings from research, if any — file paths, patterns, conventions}

---

## Phase 1: {Phase Name}

{Include full plan content from phase-1-PLAN.md}

---

## Phase 2: {Phase Name}

{Include full plan content from phase-2-PLAN.md}

---

{... repeat for all phases}

## Final Validation
- [ ] All phase validation commands pass
- [ ] Requirements checklist verified
- [ ] No regressions introduced
```

**Important**: The exported plan must be **self-contained** — it includes all context, requirements, and codebase notes needed for execution. A fresh Claude session reading only this file should understand everything.

3. Update `.planning/STATE.md`:
   - State: EXPORTED
   - Plans: autopilot-PLAN.md

## Step 5: Output Launch Command

Tell the user:

```
Plan exported to .planning/autopilot-PLAN.md

To execute in a new Walter session:
  WALTER_PLAN_FILE=.planning/autopilot-PLAN.md bash plan-executor.sh

Or to execute specific phases:
  WALTER_WAVE="1,2,3" WALTER_PLAN_FILE=.planning/autopilot-PLAN.md bash plan-executor.sh
```

User input: $ARGUMENTS
