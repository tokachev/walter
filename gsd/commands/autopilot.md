---
description: "Interactive planning across all phases, then export a single self-contained plan file (no execution)"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# GSD: Autopilot

Full interactive GSD planning (with discussions and clarifications), but instead of executing phase-by-phase, all phases are planned upfront and exported into one self-contained plan file. Autopilot is a **planning-only mode** — it does not execute anything.

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

Create `.planning/` structure: `PROJECT.md`, `REQUIREMENTS.md`, `ROADMAP.md`, `STATE.md`.

Present the roadmap with all phases to the user for confirmation before proceeding.

## Step 3: Plan Each Phase Interactively

For each phase in `ROADMAP.md`, do the following **interactively** (do NOT skip discussions):

### 3a. Explore Phase

Before asking the user anything, launch an Explore subagent to analyze the codebase relevant to this phase.

The agent should investigate:
- Existing patterns and conventions in code areas this phase will touch
- Files that will likely be affected (list with paths)
- Dependencies and interconnections between affected components
- Test coverage for the affected areas (existing tests, test patterns used)
- If this phase is SQL-heavy, note that validation queries replace unit tests

```
Agent(subagent_type="Explore", prompt="Analyze the codebase areas relevant to Phase {N}: {phase description}. Investigate: existing patterns and conventions, files that will be affected, dependencies between components, test coverage. Be specific with file paths and line numbers.")
```

Write findings to `.planning/phases/phase-{N}-EXPLORE.md`.

Present a **3-5 bullet summary** of key findings to the user before proceeding to discussion.

### 3b. Discuss Phase

**CRITICAL**: Ask ONE question at a time using AskFollowupQuestion. Wait for the user's response before asking the next question. Do NOT batch multiple questions into a single message.

#### Question 1: Scope
Present the phase scope from the roadmap and exploration findings, then ask:
> "Here's what this phase covers: {summary}. Does this scope look right, or do you want to add/remove anything?"

Wait for response.

#### Question 2: Implementation Approach
Propose **2-3 implementation approaches** with trade-offs. Lead with the recommended option. Present as a numbered list via AskFollowupQuestion.

**Skip this step** if the approach is obvious (only one reasonable way) or the user already specified it.

Wait for response.

#### Question 3: Key Decisions
Based on the chosen approach, present specific technical decisions that need to be made. If the decision is open-ended, ask free-form.

Wait for response.

Capture all decisions in `.planning/phases/phase-{N}-CONTEXT.md`:

```markdown
# Phase {N} Context: {phase name}

## Exploration Summary
{Key findings from Step 3a — link to full explore doc}
See: `.planning/phases/phase-{N}-EXPLORE.md`

## Approach
{Chosen implementation approach and rationale}

## Key Decisions
- {decision 1}: {rationale}
- {decision 2}: {rationale}

## Constraints
- {constraint from discussion}

## Open Questions
- {anything unresolved — to be addressed during planning}
```

### 3c. Research (if needed)

If the phase touches existing code, run Claude + Codex research in parallel:

```
Agent(subagent_type="codebase-researcher", run_in_background=true, prompt="Research areas of the codebase relevant to Phase {N}: {phase description}. Focus on: {specific areas from context}. Write findings to .claude/research/phase-{N}-research-claude.md")
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

### 3d. Create Phase Plan

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

### 3e. Validate Plan

Spawn qa-validator to check the plan before presenting to the user:

```
Agent(subagent_type="qa-validator", prompt="Review the plan at .planning/phases/phase-{N}-PLAN.md against .planning/REQUIREMENTS.md. Check:
1. All requirements for this phase are covered
2. Tasks are in logical order with correct dependencies
3. Validation commands are present and meaningful
4. No gaps or ambiguities in the steps
Report any issues found.")
```

If qa-validator reports issues, fix the plan before proceeding.

### 3f. Review Plan with User

Present the created plan to the user along with:
- **qa-validator findings** (issues found and how they were resolved, or confirmation that plan passed)
- **Agent Notes** section so the user can see where Claude and Codex converged or diverged

Ask:
- Does this plan look right?
- Any tasks to add/remove/modify?

Apply any changes before moving to the next phase.

**Repeat 3a-3f for every phase in the roadmap.**

## Step 4: Export Combined Plan

After ALL phases are planned:

1. Read all `.planning/phases/phase-*-PLAN.md` files in order.
2. Renumber all `### Task N:` headers sequentially across the entire plan (Phase 1 tasks start at 1, Phase 2 tasks continue from where Phase 1 ended, etc.). This ensures every task has a unique number in the final document.
3. Create a single self-contained plan file at `.planning/autopilot-PLAN.md`:

```markdown
# Autopilot Plan: {Project Name}

## Project Context
{Summary from PROJECT.md — goal, constraints, tech stack}

## Requirements
### Must Have
{Must-have requirements from REQUIREMENTS.md}

### Should Have
{Should-have requirements from REQUIREMENTS.md}

## Codebase Notes
{Key findings from research — file paths, patterns, conventions, integration points}

---

## Phase 1: {Phase Name}

{Include full plan content from phase-1-PLAN.md}

### Phase 1 Validation
```bash
# validation commands for phase 1
```

---

## Phase 2: {Phase Name}

{Include full plan content from phase-2-PLAN.md}

### Phase 2 Validation
```bash
# validation commands for phase 2
```

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

## Step 5: Output Result

Tell the user:

```
Plan exported to .planning/autopilot-PLAN.md

Review the plan and use your preferred execution method when ready.
```

User input: $ARGUMENTS
