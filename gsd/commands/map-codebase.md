---
description: "Deep codebase analysis: spawn parallel researchers for stack, architecture, conventions, and concerns"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# GSD: Map Codebase

Comprehensive codebase analysis by spawning 4 parallel codebase-researcher agents.

## Step 1: Launch Parallel Research

Spawn all 4 agents simultaneously:

### Agent 1: Stack Analysis
```
Agent(subagent_type="codebase-researcher", prompt="Analyze the tech stack of the codebase at /workspace. Document: languages, frameworks, package managers, runtime versions, key dependencies, build tools, test frameworks. Write to .claude/research/map-stack.md")
```

### Agent 2: Architecture
```
Agent(subagent_type="codebase-researcher", prompt="Map the architecture of the codebase at /workspace. Document: directory structure, module boundaries, data flow, entry points, API surface, database interactions, external service integrations. Write to .claude/research/map-architecture.md")
```

### Agent 3: Conventions
```
Agent(subagent_type="codebase-researcher", prompt="Identify coding conventions in the codebase at /workspace. Document: naming patterns, file organization, error handling patterns, logging approach, configuration management, test patterns, code style. Write to .claude/research/map-conventions.md")
```

### Agent 4: Concerns
```
Agent(subagent_type="codebase-researcher", prompt="Identify potential concerns in the codebase at /workspace. Document: TODO/FIXME/HACK comments, code duplication, missing tests, hardcoded values, security concerns, performance bottlenecks, deprecated dependencies. Write to .claude/research/map-concerns.md")
```

## Step 2: Synthesize

After all 4 agents complete, read their outputs and create a unified summary at `.claude/research/codebase-map.md`:

```markdown
# Codebase Map

## Stack
{key points from stack analysis}

## Architecture
{key points from architecture analysis}

## Conventions
{key patterns to follow}

## Concerns
{top issues to be aware of}
```

## Step 3: Report

Present the synthesized map to the user. Suggest next steps based on findings.

User input: $ARGUMENTS
