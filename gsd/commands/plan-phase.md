---
description: "Research codebase, create execution plans, and validate them for current phase"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# GSD: Plan Phase

You are creating execution plans for the current GSD phase.

## Step 1: Load Context

1. Read `.planning/STATE.md` for current phase number
2. Read `.planning/REQUIREMENTS.md`
3. Read `.planning/phases/phase-{N}-CONTEXT.md` for decisions
4. Read `.planning/PROJECT.md`

## Step 2: Research (if needed)

If the phase touches existing code, spawn codebase-researcher:

```
Agent(subagent_type="codebase-researcher", prompt="Research areas of the codebase relevant to Phase {N}: {phase description}. Focus on: {specific areas from context}. Write findings to .claude/research/phase-{N}-research.md")
```

Wait for research results before proceeding.

## Step 3: Create Plans

Spawn walter-planner to create the execution plan(s):

```
Agent(subagent_type="walter-planner", prompt="Create execution plan(s) for Phase {N}.

Context:
- Requirements: {from REQUIREMENTS.md}
- Decisions: {from phase-N-CONTEXT.md}
- Research: {from .claude/research/ if available}

Write plan(s) to .planning/phases/phase-{N}-{P}-PLAN.md using this format:
- ### Task N: headers (required for plan-executor)
- - [ ] checklist items
- - [WAIT] for manual gates
- Max 10 tasks per plan, 3-7 items per task
- Include ## Validation Commands section

If the phase is large, split into multiple plans (phase-{N}-1-PLAN.md, phase-{N}-2-PLAN.md).
Each plan should be independently executable.")
```

## Step 4: Validate Plans

Spawn qa-validator as a plan checker:

```
Agent(subagent_type="qa-validator", prompt="Review the plan(s) in .planning/phases/phase-{N}-*-PLAN.md against .planning/REQUIREMENTS.md. Check:
1. All requirements for this phase are covered
2. Tasks are in logical order with correct dependencies
3. Validation commands are present and meaningful
4. No gaps or ambiguities in the steps
Report any issues found.")
```

If issues found, fix the plans based on feedback.

## Step 5: Update State

Update `.planning/STATE.md`:
- State: PLANNED
- Updated: {ISO timestamp}
- Plans: {list of created plan files}

Suggest next step: `/gsd:execute-phase` to run the plans.

User input: $ARGUMENTS
