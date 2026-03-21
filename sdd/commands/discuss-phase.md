---
description: "Capture decisions and context for a phase before planning"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# SDD: Discuss Phase

You are facilitating a discussion to capture decisions for a SDD phase.

## Step 0: Explore Codebase

Before asking the user anything, launch an Explore subagent via Task() to analyze the codebase relevant to this phase.

The agent should investigate:
- Existing patterns and conventions in code areas this phase will touch
- Files that will likely be affected (list with paths)
- Dependencies and interconnections between affected components
- Test coverage for the affected areas (existing tests, test patterns used)
- If this phase is SQL-heavy (queries, views, stored procedures, pipeline logic, transformations), note that **validation queries replace unit tests** — flag this for planning

Write the full findings to `.planning/phases/phase-{N}-EXPLORE.md`.

After the agent completes, present a **3-5 bullet summary** of the key findings to the user before proceeding to questions.

## Step 1: Load Context

1. Read `.planning/STATE.md` to get current phase number
2. Read `.planning/ROADMAP.md` to understand what this phase delivers
3. Read `.planning/REQUIREMENTS.md` for full requirements
4. Read `.planning/PROJECT.md` for project context

## Step 2: Facilitate Discussion (One Question at a Time)

**CRITICAL**: Ask ONE question at a time using AskFollowupQuestion. Wait for the user's response before asking the next question. Do NOT batch multiple questions into a single message.

### Question 1: Scope
Present the phase scope from the roadmap and ask:
> "Here's what this phase covers: {summary}. Does this scope look right, or do you want to add/remove anything?"

Wait for response.

### Step 1.5: Propose Implementation Approaches
After the scope is confirmed, propose **2-3 implementation approaches** with trade-offs. Lead with the recommended option. Present as a numbered list via AskFollowupQuestion.

**Skip this step** if the approach is obvious (only one reasonable way) or the user already specified it.

Wait for response.

### Question 2: Key Decisions
Based on the chosen approach, present specific alternatives as a numbered list via AskFollowupQuestion. If the decision is open-ended, ask free-form.

Wait for response.

### Question 3: Risks & Edge Cases
> "Any risks or edge cases you're aware of that we should account for?"

Wait for response.

### Question 4: Dependencies
> "Are there external dependencies (services, APIs, data sources) we need to coordinate with?"

Wait for response.

### Question 5: Testing Preference
Ask via AskFollowupQuestion with these options:
1. TDD (tests first)
2. Regular (code first, then tests)
3. Validation queries only (SQL-heavy phase)

Wait for response. Store the preference in the context file.

If $ARGUMENTS contains specific topics, focus on those and skip irrelevant questions.

## Step 3: Write Context File

Capture all decisions in `.planning/phases/phase-{N}-CONTEXT.md`:

```markdown
# Phase {N} Context: {phase name}

## Exploration Summary
{Key findings from Step 0 — link to full explore doc}
See: `.planning/phases/phase-{N}-EXPLORE.md`

## Approach
{Chosen implementation approach and rationale}

## Key Decisions
- {decision 1}: {rationale}
- {decision 2}: {rationale}

## Testing Preference
{TDD or Regular — as chosen by user}
{If SQL-heavy phase: "Validation queries replace unit tests for SQL tasks"}

## Constraints
- {constraint from discussion}

## Open Questions
- {anything unresolved — to be addressed during planning}
```

## Step 4: Update State

Update `.planning/STATE.md`:
- State: DISCUSSING
- Updated: {ISO timestamp}
- Notes: Context captured for phase {N}

Suggest next step: `/sdd:plan-phase` to create execution plans.

User input: $ARGUMENTS
