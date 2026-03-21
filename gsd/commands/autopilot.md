---
description: "Interactive planning across all phases, then export a single self-contained plan for autonomous execution"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# GSD: Autopilot

Full interactive GSD planning (with discussions and clarifications), but instead of executing phase-by-phase, all phases are planned upfront and exported into one self-contained plan file for autonomous execution in a fresh Walter session.

## Step 0: Load Lessons

Check if `tasks/lessons.md` exists:
- **If yes**: Read the `## Rules Index` section. Keep these rules in context for all planning decisions. Flag any rules that are directly relevant to the current project scope.
- **If no**: Skip — no lessons captured yet.

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
Agent(subagent_type="codebase-researcher", run_in_background=true, prompt="Research the codebase at /workspace for: project structure, tech stack, key patterns and conventions, areas relevant to the requested project. Write findings to .claude/research/gsd-codebase-overview-claude.md")
```

Run Codex in parallel — execute the following command using the Bash tool. First verify codex is available with `command -v codex`. If codex is not found, skip and note degraded mode:

```bash
mkdir -p .claude/research
codex exec -s danger-full-access <<'CODEX_EOF' 2>&1 | tee .claude/research/gsd-codebase-overview-codex.md
Analyze this codebase for the requested project setup. Document:

1. Project structure and entry points
2. Tech stack and key dependencies
3. Established implementation patterns and constraints
4. Risks or integration hotspots relevant to the requested work

Output structured markdown with concrete file references.
CODEX_EOF
```

Merge both into `.claude/research/gsd-codebase-overview.md` before writing `.planning/PROJECT.md`, `.planning/REQUIREMENTS.md`, and `.planning/ROADMAP.md`.

If Codex is unavailable, continue with Claude-only research but say so explicitly.

Create `.planning/` structure: `PROJECT.md`, `REQUIREMENTS.md`, `ROADMAP.md`, `STATE.md`, `REQUIREMENTS-CHANGELOG.md`.

The `REQUIREMENTS-CHANGELOG.md` tracks delta specs (ADDED/MODIFIED/REMOVED requirements) across phases:
```markdown
# Requirements Changelog

Tracks all requirement changes across phases using delta specs (ADDED/MODIFIED/REMOVED).
Delta specs are merged into REQUIREMENTS.md via `/gsd:sync-specs`.

## Phase Deltas
(populated during execution)
```

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

If the phase touches existing code, run Claude + Codex research in parallel:

```
Agent(subagent_type="codebase-researcher", run_in_background=true, prompt="Research areas of the codebase relevant to Phase {N}: {phase description}. Focus on the files, dependencies, patterns, and risks most likely to affect implementation. Write findings to .claude/research/phase-{N}-research-claude.md")
```

Execute the following command using the Bash tool. First verify codex is available with `command -v codex`. If codex is not found, skip and note degraded mode:

```bash
mkdir -p .claude/research
codex exec -s danger-full-access <<'CODEX_EOF' 2>&1 | tee .claude/research/phase-{N}-research-codex.md
Research the codebase for Phase {N}: {phase description}.

Context:
- Requirements: {paste key requirements for this phase}
- Decisions: {paste key decisions from phase-{N}-CONTEXT.md}

Focus on relevant files, existing patterns, integration points, likely conflicts, and validation strategy.
Output structured markdown with concrete file references.
CODEX_EOF
```

Merge both into `.claude/research/phase-{N}-research.md` with:
- shared findings
- Claude-only insights
- Codex-only insights
- contradictions / open questions
- planning implications

If Codex is unavailable, continue with Claude-only research but explicitly mark degraded mode.

### 3c. Create Phase Plan

Spawn `plan-coordinator` so the final phase plan is synthesized from two independent plan drafts:

```
Agent(subagent_type="plan-coordinator", prompt="
PHASE_NUMBER: {N}
PHASE_DESCRIPTION: {phase description}
OUTPUT_PATH: .planning/phases/phase-{N}-PLAN.md

REQUIREMENTS:
{paste full requirements for this phase}

DECISIONS:
{paste full content of phase-{N}-CONTEXT.md}

RESEARCH:
{paste key findings from .claude/research/phase-{N}-research.md}
")
```

### 3d. Review Plan with User

Present the created plan to the user. Ask:
- Does this plan look right?
- Any tasks to add/remove/modify?

Also surface the `## Agent Notes` section so the user can see where Claude and Codex converged or diverged.

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

## Post-Phase Instructions (apply after each phase)

### Delta Specs
After executing each phase, check if requirements changed during implementation:
- ADDED: new requirements discovered
- MODIFIED: requirements adjusted based on reality
- REMOVED: requirements found infeasible
Append changes to `.planning/REQUIREMENTS-CHANGELOG.md`. Skip if no changes.

### 3D Verification
Verify each phase across three dimensions:
1. **Completeness**: All requirements implemented? All tasks [x]?
2. **Correctness**: Implementation matches spec intent? Edge cases handled?
3. **Coherence**: Design decisions consistent? No scope creep?

Classify issues as CRITICAL (blocks delivery) / WARNING (should fix) / SUGGESTION (nice to have).

## Final Validation (3D)
- [ ] **Completeness**: All requirements from REQUIREMENTS.md implemented and verified
- [ ] **Correctness**: All phase validation commands pass, edge cases handled
- [ ] **Coherence**: All changes consistent with design decisions, no scope creep
- [ ] Delta specs synced to REQUIREMENTS.md
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

After execution completes successfully, run:
```
/gsd:sync-specs      # Merge requirement changes into REQUIREMENTS.md
/gsd:archive project # Archive all phases with full audit trail
```

User input: $ARGUMENTS
