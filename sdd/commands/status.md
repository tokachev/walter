---
description: "Show current SDD project status: state, phase, progress"
allowed-tools: Read, Glob, Grep
---

# SDD: Status

Report the current SDD project status.

## Steps

1. Read `.planning/STATE.md` — if not found, report "No SDD project initialized. Use /sdd:new-project to start."
2. Read `.planning/ROADMAP.md` for phase overview
3. Read `.planning/PROJECT.md` for project name
4. Scan `.planning/phases/` for all plan files
5. For each plan file, count `- [ ]` (pending) vs `- [x]` (done) items

## Output Format

```
Project: {name}
Phase: {N}/{total} — {phase name}
State: {current state}

Roadmap:
  Phase 1: {name} — {COMPLETE|IN PROGRESS|PENDING}
  Phase 2: {name} — {status}
  ...

Current Phase Plans:
  {plan-file}: {done}/{total} items ({percentage}%)
  ...

Last Updated: {timestamp from STATE.md}
```

User input: $ARGUMENTS
