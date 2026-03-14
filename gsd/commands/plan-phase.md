---
description: "Research codebase, create execution plans, and validate them for current phase"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# GSD: Plan Phase

You are creating execution plans for the current GSD phase using dual-agent analysis (Claude + Codex in parallel).

## Step 1: Load Context

1. Read `.planning/STATE.md` for current phase number
2. Read `.planning/REQUIREMENTS.md`
3. Read `.planning/phases/phase-{N}-CONTEXT.md` for decisions
4. Read `.planning/PROJECT.md`

## Step 2: Dual Research (if phase touches existing code)

Run Claude and Codex research in parallel:

### Claude Research
```
Agent(subagent_type="codebase-researcher", prompt="Research areas of the codebase relevant to Phase {N}: {phase description}. Focus on: {specific areas from context}. Write findings to .claude/research/phase-{N}-research-claude.md")
```

### Codex Research

```bash
codex exec -s danger-full-access <<'CODEX_EOF' 2>&1 | tee .claude/research/phase-{N}-research-codex.md
Research the codebase for Phase {N}: {phase description}.

Context:
- Requirements: {paste key requirements from REQUIREMENTS.md}
- Decisions: {paste key decisions from phase-N-CONTEXT.md}

Focus on: {specific areas from context}

Analyze: relevant files, existing patterns, dependencies, potential conflicts, edge cases.
Be specific — reference exact file paths and line numbers.

Output a structured markdown document with your findings.
CODEX_EOF
```

### Merge Research

After both complete, read:
1. `.claude/research/phase-{N}-research-claude.md`
2. `.claude/research/phase-{N}-research-codex.md`

Produce merged research at `.claude/research/phase-{N}-research.md`:
- Combine agreed-upon findings (high confidence)
- Note unique insights from each agent
- Flag any contradictions for consideration during planning

## Step 3: Coordinated Planning

Spawn the plan-coordinator agent. This agent launches Claude planner and Codex planner in parallel, compares their outputs, resolves divergences, and synthesizes the final plan.

```
Agent(subagent_type="plan-coordinator", prompt="
PHASE_NUMBER: {N}
PHASE_DESCRIPTION: {phase description from ROADMAP.md}
OUTPUT_PATH: .planning/phases/phase-{N}-1-PLAN.md

REQUIREMENTS:
{paste full requirements for this phase from REQUIREMENTS.md}

DECISIONS:
{paste full content of phase-{N}-CONTEXT.md}

RESEARCH:
{paste key findings from .claude/research/phase-{N}-research.md}
")
```

The coordinator will:
1. Spawn walter-planner (Claude) and codex exec in parallel
2. Compare both plans across task breakdown, completeness, approach, ordering
3. Optionally resume the Claude planner for clarification on divergences
4. Synthesize the final plan at the OUTPUT_PATH
5. Document divergences in ## Agent Notes section

After the coordinator finishes, read the final plan to verify it was written correctly.

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
