---
description: "Capture decisions and context for a phase before planning"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# GSD: Discuss Phase

You are facilitating a discussion to capture decisions for a GSD phase.

## Step 1: Load Context

1. Read `.planning/STATE.md` to get current phase number
2. Read `.planning/ROADMAP.md` to understand what this phase delivers
3. Read `.planning/REQUIREMENTS.md` for full requirements
4. Read `.planning/PROJECT.md` for project context

## Step 2: Facilitate Discussion

Present the phase scope to the user and discuss:
- **Approach**: How should we implement this? What patterns to use?
- **Decisions**: Any technical choices to make (libraries, architecture, etc.)
- **Risks**: What could go wrong? Edge cases?
- **Dependencies**: External services, APIs, data sources?

If $ARGUMENTS contains specific topics, focus on those.

## Step 3: Write Context File

Capture all decisions in `.planning/phases/phase-{N}-CONTEXT.md`:

```markdown
# Phase {N} Context: {phase name}

## Approach
{How we're implementing this}

## Key Decisions
- {decision 1}: {rationale}
- {decision 2}: {rationale}

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
