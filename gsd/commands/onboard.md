---
description: "Interactive GSD tutorial using your real codebase — learn by doing"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# GSD: Onboard

Interactive walkthrough of the GSD (Get Stuff Done) workflow. Duration: ~15-30 minutes.

## Step 1: Welcome & Context

Check if `.planning/` exists:
- **If yes**: Read STATE.md and show current project status. Offer: "You have an active project. Want to learn GSD alongside it, or start a fresh tutorial?"
- **If no**: Continue with fresh tutorial.

Present GSD philosophy:
> GSD is a structured development workflow with a strict state machine, dual-model research (Claude + Codex in parallel), mandatory verification, and a lessons-learned system. It ensures high-confidence delivery through rigorous planning and execution.

## Step 2: State Machine Tour

Present the GSD state machine:

```
INIT → DISCUSSING → PLANNED → EXECUTING → VERIFYING → PHASE_COMPLETE → ARCHIVED
```

Explain each transition:
- **INIT**: Project initialized with brief, requirements, roadmap
- **DISCUSSING**: User decisions captured for current phase
- **PLANNED**: Execution plans created via dual-model synthesis (Claude + Codex)
- **EXECUTING**: Plans executed wave-by-wave with test enforcement
- **VERIFYING**: 3D QA validation (Completeness, Correctness, Coherence) + user acceptance
- **PHASE_COMPLETE**: Phase accepted, ready for next phase
- **ARCHIVED**: Phase or project archived with full audit trail

## Step 3: Two Workflows

Explain the two main ways to use GSD:

### Phase-by-Phase (Interactive)
Best for: exploratory work, unclear requirements, learning.
```
/gsd:new-project → /gsd:discuss-phase → /gsd:plan-phase → /gsd:execute-phase → /gsd:verify-work
                                                                                      ↓
                                                                              /gsd:archive
```
Each phase is discussed, planned, executed, and verified individually.

### Autopilot (Full Planning Upfront)
Best for: clear requirements, autonomous execution, ~70% of use cases.
```
/gsd:autopilot → exports single autopilot-PLAN.md → execute in fresh session
```
All phases planned interactively upfront, then exported as one self-contained plan for autonomous execution. Includes post-phase delta specs tracking and 3D verification.

## Step 4: Guided Walkthrough

Ask the user via AskFollowupQuestion:
> "Want to try a small real improvement on this codebase, or walk through with a hypothetical example?"

### Option A: Real Improvement
1. Spawn codebase-researcher to find small improvement candidates:
```
Agent(subagent_type="codebase-researcher", prompt="Find 2-3 small, low-risk improvements in this codebase: missing docs, small refactors, test gaps, or code quality fixes. Each should be completable in under 30 minutes. List candidates with file paths and descriptions.")
```
2. Present candidates and let user pick one
3. Walk through each GSD step, explaining what happens and why:
   - **Discuss**: "Now we'd normally capture decisions via `/gsd:discuss-phase`..."
   - **Plan**: "The plan-coordinator would launch Claude and Codex planners in parallel..."
   - **Execute**: "The plan-executor follows the plan precisely, with elegance checks..."
   - **Verify**: "QA validates across 3 dimensions: Completeness, Correctness, Coherence..."
4. Optionally execute the improvement (ask user)

### Option B: Hypothetical
1. Use a simple example (e.g., "add a health check endpoint")
2. Show what each artifact would look like:
   - `.planning/PROJECT.md` — project goal and constraints
   - `.planning/REQUIREMENTS.md` — must have / should have / out of scope
   - `.planning/ROADMAP.md` — phases with descriptions
   - `.planning/phases/phase-1-CONTEXT.md` — decisions from discussion
   - `.planning/phases/phase-1-PLAN.md` — execution plan with checklist
   - `.planning/phases/phase-1-RESULTS.md` — what was delivered
   - `.planning/REQUIREMENTS-CHANGELOG.md` — delta specs
3. Explain dual-model philosophy: both Claude and Codex research and plan independently, then a coordinator synthesizes the best of both

## Step 5: Key Features Deep Dive

Based on the user's interest (ask if unclear), highlight:

### For Developers
- **elegance-reviewer**: Challenges planned approach before execution — "Is there a simpler way?"
- **plan-executor**: Follows plans precisely, no improvisation. Tests mandatory after every task
- **gsd-debugger**: Diagnoses failures, creates minimal fix plans (max 3 tasks)

### For Leads / PMs
- **status**: Check progress at any time with `/gsd:status`
- **verify-work**: 3D verification (Completeness/Correctness/Coherence) with severity levels
- **archive**: Full audit trail with archive summaries
- **delta specs**: Track how requirements evolved via REQUIREMENTS-CHANGELOG.md

### For Everyone
- **lessons**: System captures mistakes and patterns in `tasks/lessons.md`, loaded at session start
- **dual-model**: Two AI perspectives catch blindspots — divergences are flagged and resolved

## Step 6: Cheat Sheet

Print the quick-reference card:

```
━━━ GSD Command Reference ━━━

SETUP
  /gsd:new-project   — Initialize project (brief → research → roadmap)
  /gsd:onboard       — This interactive tutorial

PLANNING
  /gsd:discuss-phase — Discuss current phase decisions (1 question at a time)
  /gsd:plan-phase    — Create execution plans (dual-model: Claude + Codex)
  /gsd:autopilot     — Plan ALL phases upfront → export for autonomous execution

EXECUTION
  /gsd:execute-phase — Run plans wave-by-wave with verification
  /gsd:quick         — Fast path for small tasks (research → plan → execute)

VERIFICATION
  /gsd:verify-work   — UAT acceptance (3D: Completeness/Correctness/Coherence)

MAINTENANCE
  /gsd:sync-specs    — Merge requirement changes (delta specs) into REQUIREMENTS.md
  /gsd:archive       — Archive completed phases with full audit trail
  /gsd:status        — Check progress (phase, state, plan completion %)
  /gsd:capture-lesson — Record a lesson learned after corrections/failures
  /gsd:map-codebase  — Deep 5-agent codebase analysis (stack, arch, patterns)
```

## Step 7: What's Next?

Suggest the best starting point based on context:
- No project exists → `/gsd:new-project` to set up, or `/gsd:quick "{task}"` for a fast start
- Project in progress → `/gsd:status` to check where things stand
- Want autonomous execution → `/gsd:autopilot` to plan everything upfront
- First time → `/gsd:quick "small improvement"` for a quick win

User input: $ARGUMENTS
