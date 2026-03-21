---
description: "Initialize a new SDD project with interactive brief, requirements, roadmap, and state tracking"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# SDD: New Project

You are initializing a new SDD (Spec-Driven Development) project. Follow these steps:

## Step 1: Interactive Brief

Ask the user these questions (skip any they've already answered in $ARGUMENTS):
1. **What are we building?** (one paragraph) — *free-form text*
2. **What's the desired outcome?** (what does "done" look like) — *free-form text*
3. **Any constraints?** (tech stack, timeline, compatibility requirements)
4. **Is there existing code to work with?** (if yes, we'll research it) — *free-form text*

## Step 2: Dual Codebase Research (if existing code)

If working with existing code, run Claude and Codex research in parallel. Start Claude in the background, then run Codex immediately so both sessions overlap.

### Claude Research
```
Agent(subagent_type="codebase-researcher", run_in_background=true, prompt="Research the codebase at /workspace for: project structure, tech stack, key patterns and conventions, areas relevant to: {brief summary}. Write findings to .claude/research/sdd-codebase-overview-claude.md")
```

### Codex Research

Execute the following command using the Bash tool. First verify codex is available with `command -v codex`. If codex is not found, skip to Merge Research and warn the user.

```bash
mkdir -p .claude/research
codex exec -s danger-full-access <<'CODEX_EOF' 2>&1 | tee .claude/research/sdd-codebase-overview-codex.md
Analyze this codebase. Document:

1. **Project structure** — directory layout, key files, entry points
2. **Tech stack** — languages, frameworks, versions, dependencies
3. **Key patterns** — coding conventions, architectural patterns, testing approach
4. **Areas relevant to**: {brief summary of what we're building}

Be specific — reference exact file paths. Output structured markdown.
CODEX_EOF
```

### Merge Research

After both complete, read both files and produce merged overview at `.claude/research/sdd-codebase-overview.md`:
- Combine agreed-upon findings
- Note unique insights from each
- Flag contradictions (if any) for the user

**If Codex is unavailable** (command not found or exec fails): warn the user that Codex research was skipped, then continue with Claude-only research. Do NOT silently skip Codex.

## Step 3: Create .planning/ Structure

Base `.planning/PROJECT.md`, `.planning/REQUIREMENTS.md`, and `.planning/ROADMAP.md` on the merged overview when research exists, not on a single-agent output.

Create these files:

### `.planning/PROJECT.md`
```markdown
# {Project Name}

## Goal
{From user's answers}

## Constraints
{From user's answers}

## Tech Stack
{From research or user input}
```

### `.planning/REQUIREMENTS.md`
```markdown
# Requirements

## Must Have
- {requirement 1}
- {requirement 2}

## Should Have
- {requirement}

## Out of Scope
- {explicitly excluded items}
```

### `.planning/ROADMAP.md`
```markdown
# Roadmap

## Phase 1: {name}
{description — what this phase delivers}

## Phase 2: {name}
{description}
```

### `.planning/REQUIREMENTS-CHANGELOG.md`
```markdown
# Requirements Changelog

Tracks all requirement changes across phases using delta specs (ADDED/MODIFIED/REMOVED).
Delta specs are merged into REQUIREMENTS.md via `/sdd:sync-specs`.

## Phase Deltas
(populated during execution)
```

### `.planning/STATE.md`
```markdown
# SDD State

- Project: {name}
- Current Phase: 1
- State: INIT
- Updated: {ISO timestamp}
- Plans: none
- Notes: Project initialized
```

## Step 4: Confirm

Present the created structure to the user. If dual research was run, call out:
- Where Claude and Codex agreed
- Any contradictions that influenced the roadmap

Then suggest next step:
- `/sdd:discuss-phase` to discuss Phase 1 details
- `/sdd:quick` if they want to skip straight to execution

User input: $ARGUMENTS
