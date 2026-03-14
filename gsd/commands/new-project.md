---
description: "Initialize a new GSD project with interactive brief, requirements, roadmap, and state tracking"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# GSD: New Project

You are initializing a new GSD (Get Stuff Done) project. Follow these steps:

## Step 1: Interactive Brief

Ask the user these questions (skip any they've already answered in $ARGUMENTS):
1. **What are we building?** (one paragraph)
2. **What's the desired outcome?** (what does "done" look like)
3. **Any constraints?** (tech stack, timeline, compatibility requirements)
4. **Is there existing code to work with?** (if yes, we'll research it)

## Step 2: Dual Codebase Research (if existing code)

If working with existing code, run Claude and Codex research in parallel:

### Claude Research
```
Agent(subagent_type="codebase-researcher", run_in_background=true, prompt="Research the codebase at /workspace for: project structure, tech stack, key patterns and conventions, areas relevant to: {brief summary}. Write findings to .claude/research/gsd-codebase-overview-claude.md")
```

### Codex Research
```bash
codex exec -s danger-full-access <<'CODEX_EOF' 2>&1 | tee .claude/research/gsd-codebase-overview-codex.md
Analyze this codebase. Document:

1. **Project structure** — directory layout, key files, entry points
2. **Tech stack** — languages, frameworks, versions, dependencies
3. **Key patterns** — coding conventions, architectural patterns, testing approach
4. **Areas relevant to**: {brief summary of what we're building}

Be specific — reference exact file paths. Output structured markdown.
CODEX_EOF
```

### Merge Research

After both complete, read both files and produce merged overview at `.claude/research/gsd-codebase-overview.md`:
- Combine agreed-upon findings
- Note unique insights from each
- Flag contradictions (if any) for the user

## Step 3: Create .planning/ Structure

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

### `.planning/STATE.md`
```markdown
# GSD State

- Project: {name}
- Current Phase: 1
- State: INIT
- Updated: {ISO timestamp}
- Plans: none
- Notes: Project initialized
```

## Step 4: Confirm

Present the created structure to the user and suggest next step:
- `/gsd:discuss-phase` to discuss Phase 1 details
- `/gsd:quick` if they want to skip straight to execution

User input: $ARGUMENTS
