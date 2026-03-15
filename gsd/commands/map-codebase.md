---
description: "Deep codebase analysis: spawn parallel researchers for stack, architecture, conventions, and concerns"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# GSD: Map Codebase

Comprehensive codebase analysis using dual-agent approach (Claude + Codex in parallel).

## Step 1: Launch Parallel Research

Spawn all 5 agents simultaneously — 4 Claude researchers + 1 Codex researcher:

### Agent 1: Stack Analysis (Claude)
```
Agent(subagent_type="codebase-researcher", run_in_background=true, prompt="Analyze the tech stack of the codebase at /workspace. Document: languages, frameworks, package managers, runtime versions, key dependencies, build tools, test frameworks. Write to .claude/research/map-stack.md")
```

### Agent 2: Architecture (Claude)
```
Agent(subagent_type="codebase-researcher", run_in_background=true, prompt="Map the architecture of the codebase at /workspace. Document: directory structure, module boundaries, data flow, entry points, API surface, database interactions, external service integrations. Write to .claude/research/map-architecture.md")
```

### Agent 3: Conventions (Claude)
```
Agent(subagent_type="codebase-researcher", run_in_background=true, prompt="Identify coding conventions in the codebase at /workspace. Document: naming patterns, file organization, error handling patterns, logging approach, configuration management, test patterns, code style. Write to .claude/research/map-conventions.md")
```

### Agent 4: Concerns (Claude)
```
Agent(subagent_type="codebase-researcher", run_in_background=true, prompt="Identify potential concerns in the codebase at /workspace. Document: TODO/FIXME/HACK comments, code duplication, missing tests, hardcoded values, security concerns, performance bottlenecks, deprecated dependencies. Write to .claude/research/map-concerns.md")
```

### Agent 5: Full Analysis (Codex)

Run Codex in parallel with Claude agents — execute the following command using the Bash tool. First verify codex is available with `command -v codex`. If codex is not found, skip and note degraded mode in the final summary:

```bash
mkdir -p .claude/research
codex exec -s danger-full-access <<'CODEX_EOF' 2>&1 | tee .claude/research/map-codex.md
Perform a comprehensive analysis of the codebase. Cover all of the following:

1. **Tech Stack**: languages, frameworks, package managers, runtime versions, key dependencies, build tools, test frameworks
2. **Architecture**: directory structure, module boundaries, data flow, entry points, API surface, database interactions, external integrations
3. **Conventions**: naming patterns, file organization, error handling, logging, configuration, test patterns, code style
4. **Concerns**: TODO/FIXME/HACK comments, code duplication, missing tests, hardcoded values, security issues, performance bottlenecks, deprecated dependencies

Output a single structured markdown document covering all 4 areas. Be specific — reference exact files and line numbers.
CODEX_EOF
```

If Codex is unavailable, continue with the 4 Claude reports and note degraded mode in the final summary.

## Step 2: Synthesize Claude Findings

After all Claude agents complete, read their 4 outputs and create an intermediate summary at `.claude/research/map-claude-summary.md`:

```markdown
# Claude Analysis Summary

## Stack
{key points from map-stack.md}

## Architecture
{key points from map-architecture.md}

## Conventions
{key patterns from map-conventions.md}

## Concerns
{top issues from map-concerns.md}
```

## Step 3: Compare & Merge

Read both summaries:
1. `.claude/research/map-claude-summary.md` (Claude's combined output)
2. `.claude/research/map-codex.md` (Codex's output)

Compare and produce the final merged map at `.claude/research/codebase-map.md`:

```markdown
# Codebase Map

## Stack
{merged findings — explicitly note shared findings vs unique insights}

## Architecture
{merged findings}

## Conventions
{merged findings}

## Concerns
{merged findings, prioritized by agreement between agents}

## Divergences
{any significant points where Claude and Codex disagreed — include both perspectives so the user can decide}
```

## Step 4: Report

Present the final merged codebase map to the user. Highlight:
- Key findings both agents agreed on (high confidence)
- Unique insights from each agent
- Any divergences that need the user's judgment
- Whether the result is true dual-model output or a degraded Claude-only fallback

Suggest next steps based on findings.

User input: $ARGUMENTS
