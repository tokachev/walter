---
description: "Research codebase, create execution plans, and validate them for current phase"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# GSD: Plan Phase

You are creating execution plans for the current GSD phase using parallel dual-model planning: Claude + Codex research in parallel, then Claude + Codex planning in parallel, then comparison + synthesis into one final plan.

## Step 1: Load Context

1. Read `.planning/STATE.md` for current phase number
2. Read `.planning/REQUIREMENTS.md`
3. Read `.planning/phases/phase-{N}-CONTEXT.md` for decisions
4. Read `.planning/PROJECT.md`

## Step 2: Dual Research (if phase touches existing code)

Launch Claude research in the background, then run Codex research immediately so both sessions overlap.

### Claude Research
```
Agent(subagent_type="codebase-researcher", run_in_background=true, prompt="Research areas of the codebase relevant to Phase {N}: {phase description}. Focus on: {specific areas from context}. Write findings to .claude/research/phase-{N}-research-claude.md")
```

### Codex Research

```bash
mkdir -p .claude/research
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
- Shared findings both agents support (high confidence)
- Claude-only insights
- Codex-only insights
- Contradictions or open questions
- Planning implications and recommended focus areas

Do not plan from a single research file if the other session is still running.

If Codex is unavailable or fails, continue with Claude-only research but explicitly record degraded mode in the merged file and in the user-facing summary.

## Step 3: Coordinated Planning

Spawn the `plan-coordinator` agent. It must launch Claude planner and Codex planner in parallel from the same inputs, keep them blind to each other's plan until both finish, then compare both drafts and synthesize the final plan.

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
1. Launch `walter-planner` in background and run `codex exec` immediately so both plans are created in parallel
2. Keep both planners blind to each other's draft until both outputs exist
3. Compare both plans across task breakdown, completeness, approach, ordering, and validation quality
4. Synthesize the final plan at the OUTPUT_PATH using the merged research from Step 2
5. Document divergences and why each chosen approach won in `## Agent Notes`
6. Preserve both intermediate plan files for reference

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
