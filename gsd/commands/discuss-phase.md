---
description: "Capture decisions and context for a phase before planning"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# GSD: Discuss Phase

You are facilitating a discussion to capture decisions for a GSD phase.

## Step 0: Explore Codebase

Before asking the user anything, launch an Explore subagent via Agent(subagent_type="Explore") to analyze the codebase relevant to this phase.

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

## Step 2: Facilitate Discussion

Use **AskUserQuestion** for all choices (picker.sh does not work in Claude Code's non-interactive Bash tool). For questions with concrete options, provide them as AskUserQuestion options. For free-form questions, use AskUserQuestion with open-ended framing.

**Batching rule**: present the scope overview + approach options together in a single message (Questions 1 + 1.5). Then batch remaining questions (2-5) in a second round if they are straightforward. Only split into individual questions when a later question depends on an earlier answer.

If `$ARGUMENTS` already contains answers — skip the corresponding questions.

### Round 1: Scope + Approach

Present the phase scope from the roadmap and ask via AskUserQuestion:
1. **Scope confirmation**: "Here's what this phase covers: {summary}. Does this scope look right, or do you want to add/remove anything?"
2. **Approach** (if non-obvious): Propose 2-3 implementation approaches with trade-offs. Lead with the recommended option. Present as AskUserQuestion options.

**Skip approach question** if there's only one reasonable way or the user already specified it.

Wait for response.

### Round 2: Decisions, Risks, Testing

Based on the chosen approach, ask the remaining questions. Batch independent questions together via AskUserQuestion (up to 4 questions):

1. **Key Decisions**: If choosing between specific alternatives (library X vs Y, pattern A vs B), present as options. If open-ended, use free-form.
2. **Risks & Edge Cases**: "Any risks or edge cases you're aware of that we should account for?"
3. **Dependencies**: "Are there external dependencies (services, APIs, data sources) we need to coordinate with?"
4. **Testing Preference**: Options: "TDD (tests first)", "Regular (code first, then tests)", "Validation queries only (SQL-heavy)", "No test framework — validation only (linters, bash -n, smoke tests)"

Wait for response. Store the testing preference in the context file.

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

Suggest next step: `/gsd:plan-phase` to create execution plans.

User input: $ARGUMENTS
