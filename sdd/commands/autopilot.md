---
description: "Use for full project planning and execution. Trigger: 'autopilot', 'автопилот', 'plan everything', 'спланируй всё'"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# SDD: Autopilot

Full interactive SDD planning (with discussions and clarifications): all phases are planned upfront, exported into one self-contained plan file, and then executed task-by-task — each task in a separate agent.

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
Agent(subagent_type="codebase-researcher", prompt="Research the codebase at /workspace for: project structure, tech stack, key patterns and conventions, areas relevant to the requested project. Write findings to .claude/research/sdd-codebase-overview.md")
```

Use the research findings to write `.planning/PROJECT.md`, `.planning/REQUIREMENTS.md`, and `.planning/ROADMAP.md`.

Create `.planning/` structure: `PROJECT.md`, `REQUIREMENTS.md`, `ROADMAP.md`, `STATE.md`, `REQUIREMENTS-CHANGELOG.md`.

The `REQUIREMENTS-CHANGELOG.md` tracks delta specs (ADDED/MODIFIED/REMOVED requirements) across phases:
```markdown
# Requirements Changelog

Tracks all requirement changes across phases using delta specs (ADDED/MODIFIED/REMOVED).
Delta specs are merged into REQUIREMENTS.md via `/sdd:sync-specs`.

## Phase Deltas
(populated during execution)
```

Present the roadmap with all phases to the user for confirmation before proceeding.

## Step 3: Plan All Phases

Planning is split into 4 sub-steps. **Exploration and planning run in parallel across all phases** (background agents). **Discussion and review remain sequential per phase** (user input required between).

### 3a. Explore All Phases (parallel)

Spawn one `Explore` subagent **per phase** in parallel using `run_in_background=true`. All exploration runs concurrently — wall time is bounded by the slowest phase, not the sum.

For each phase N in `ROADMAP.md`:

```
Agent(
  subagent_type="Explore",
  run_in_background=true,
  prompt="Analyze the codebase areas relevant to Phase {N}: {phase description}. Investigate: existing patterns and conventions, files that will be affected, dependencies between components, and any existing test or validation patterns worth matching. Be specific with file paths and line numbers. Write findings to .planning/phases/phase-{N}-EXPLORE.md."
)
```

**Wait for ALL background Explore agents to complete** before proceeding to 3b. Do not start discussion until every phase's `EXPLORE.md` exists.

### 3b. Discuss Each Phase (sequential)

For each phase in `ROADMAP.md`, sequentially:

1. Read `.planning/phases/phase-{N}-EXPLORE.md` and present a **3-5 bullet summary** of key findings.
2. Ask the 3 questions below via `AskFollowupQuestion` — **one at a time, wait for each response** before asking the next. Do NOT batch them.

   **Q1 — Scope**: "Here's what Phase {N} covers: {summary}. Does this scope look right, or do you want to add/remove anything?"

   **Q2 — Approach**: Present 2-3 implementation approaches with trade-offs (lead with the recommended one). Skip this question if the approach is obvious or the user already specified it.

   **Q3 — Key decisions**: Based on the chosen approach, present specific technical decisions that need to be made.

3. Capture all decisions in `.planning/phases/phase-{N}-CONTEXT.md`:

```markdown
# Phase {N} Context: {phase name}

## Exploration Summary
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

After every phase has its `CONTEXT.md`, proceed to 3c.

### 3c. Plan All Phases (parallel)

Spawn one `walter-planner` agent **per phase** in parallel using `run_in_background=true`. Single-model planning — no codex, no plan-coordinator. Wall time is bounded by the slowest phase.

For each phase N in `ROADMAP.md`:

```
Agent(
  subagent_type="walter-planner",
  run_in_background=true,
  prompt="Create an execution plan for Phase {N}: {phase description}.

Context:
- Requirements (relevant slice of .planning/REQUIREMENTS.md): {paste phase-relevant requirements}
- Decisions: {paste full content of .planning/phases/phase-{N}-CONTEXT.md}
- Exploration findings: {paste full content of .planning/phases/phase-{N}-EXPLORE.md}

Write the plan to .planning/phases/phase-{N}-PLAN.md.

Format requirements (strict):
- Use `### Task N:` headers
- Use `- [ ]` checklist items and `- [WAIT]` for manual gates
- Max 10 tasks per plan
- 3-7 items per task
- Include `## Validation Commands` section
- Reference concrete file paths
- Tasks must be self-contained: each runs in an isolated session with no shared state, so never use phrases like 'as above' or 'continue from Task N'
"
)
```

**Wait for ALL background walter-planner agents to complete** before proceeding to 3d.

### 3d. Review Each Plan (sequential)

For each phase plan in order, present to the user:
- Plan title and task count
- 1-line summary of each task

Ask:
- "Phase {N} plan: does this look right? Any tasks to add/remove/modify?"

Apply any changes before moving to the next phase's review. The single combined `qa-validator` pass in Step 6 covers full requirement validation after execution — no per-phase qa-validator here.

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
{Aggregated key findings from `.planning/phases/phase-*-EXPLORE.md` — file paths, patterns, conventions, integration points}

---

## Phase 1: {Phase Name}

{Include full plan content from phase-1-PLAN.md with tasks numbered sequentially.
 If the phase plan defines validation steps, embed them as `- [ ]` items in the LAST task of the phase.
 Do NOT create separate `### Phase N Validation` sections — the executor ignores them.
 Do NOT invent test steps that the phase plan did not ask for.}

---

## Phase 2: {Phase Name}

{Same as above — tasks continue sequential numbering from Phase 1.}

---

{... repeat for all phases}

### Task {LAST}: Final validation
- [ ] Verify all requirements from the Requirements section above are implemented
- [ ] Verify no regressions: check that pre-existing functionality still works
- [ ] Run any project-specific validation commands that apply (linters, smoke checks, etc.) — only if the project already uses them
- [ ] If requirements changed during implementation, append delta specs to `.planning/REQUIREMENTS-CHANGELOG.md`

## Validation Commands
```bash
# Commands the executor runs after every task. Keep this minimal and only include commands that actually exist in this project.
# Leave empty if the project has no standard validation pipeline.
```
```

**Important**: The exported plan must be **self-contained** — it includes all context, requirements, and codebase notes needed for execution. A fresh Claude session reading only this file should understand everything.

**Task isolation**: Each `### Task N:` runs in a **separate agent** with zero shared state. Each agent only sees: (1) the plan preamble (everything before the first `### Task` header, capped at 200 lines), (2) the current task section, (3) `## Validation Commands`. Therefore:
- Every task must reference exact file paths — never "the file from the previous task"
- Every task must be executable by a fresh session with no knowledge of prior tasks' execution
- Never use phrases like "as above", "same as before", "continue from Task N"
- If a task depends on prior output, describe the expected file path and content structure
- All `- [ ]` checkboxes must be under `### Task N:` headers — checkboxes under `##` (H2) headers are invisible to the executor

3. Update `.planning/STATE.md`:
   - State: EXPORTED
   - Plans: autopilot-PLAN.md
   - Progress: 0/{N} tasks complete  (where {N} is the count of `### Task ` headers in the exported file)

## Step 5: Execute Plan

**CRITICAL**: Do NOT proceed to execution until the user explicitly confirms the plan. Present the exported plan summary and ask:
> "План экспортирован в `.planning/autopilot-PLAN.md`. Запускать выполнение?"

Wait for explicit confirmation (e.g., "да", "go", "запускай"). If the user wants changes — apply them first, re-present, and ask again.

After the user confirms, execute each task in a **separate agent**.

1. Read `.planning/autopilot-PLAN.md`.
2. Extract the **preamble** — everything before the first `### Task` header (capped at 200 lines).
3. Extract the `## Validation Commands` section.
4. Parse all `### Task N: {title}` sections.

For each task **sequentially** (tasks depend on prior ones):

```
Agent(subagent_type="plan-executor", prompt="
You are executing a single task from a larger plan.

## Plan Context
{preamble}

## Your Task
{full content of ### Task N, including all checklist items}

## Validation Commands
{validation commands section}

Execute this task precisely. Run validation commands after completion.
Do not modify .planning/autopilot-PLAN.md — the parent process will mark progress.
If blocked, report the blocker — do not guess or skip.
")
```

After each agent completes:
- Check the agent's result for blockers or failures
- If a task failed, stop execution and report to the user — do NOT proceed to the next task and do NOT mark the task as done
- If successful, mark progress in the plan file:
  1. Read `.planning/autopilot-PLAN.md`
  2. Locate the section `### Task {N}: {title}` — its content runs from the header to the next `### Task ` header (or to `---` / EOF if it is the last task)
  3. In that section only, replace every `- [ ]` with `- [x]`. Leave any `- [WAIT]` items untouched
  4. Use a single Edit call with the full task section as `old_string` and the updated section as `new_string` (the section is unique because of its task number, so the Edit will not collide)
  5. Update `.planning/STATE.md`: bump the `- Progress: {done}/{total} tasks complete` line and refresh `Updated:` to the current ISO timestamp
- Continue to the next task

Update `.planning/STATE.md` to `State: EXECUTING` at the start of this step.

## Step 6: Verify Delivery

After all tasks complete, spawn qa-validator:

```
Agent(subagent_type="qa-validator", prompt="Verify that the plan at .planning/autopilot-PLAN.md has been fully executed. Check:
1. All requirements from .planning/REQUIREMENTS.md are implemented
2. Validation commands pass
3. git diff shows expected changes
4. No regressions introduced
Report pass/fail for each requirement.")
```

If qa-validator reports failures:
1. Spawn sdd-debugger to diagnose and create a fix plan
2. Execute the fix plan (each task in a separate agent, same pattern as Step 5)
3. Re-verify. If still failing after 2 fix cycles, stop and report to user.

If verification passes, update `.planning/STATE.md` to `State: PHASE_COMPLETE`.

## Step 7: Output Result

Tell the user:

```
Plan executed and verified.
Results: .planning/autopilot-PLAN.md
```

After execution completes successfully, run:
```
/sdd:sync-specs      # Merge requirement changes into REQUIREMENTS.md
/sdd:archive project # Archive all phases with full audit trail
```

User input: $ARGUMENTS
