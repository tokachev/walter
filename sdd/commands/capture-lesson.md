---
description: "Capture a lesson learned from a correction, failure, or insight and append it to tasks/lessons.md"
allowed-tools: Read, Write, Edit, Glob, Grep
---

# SDD: Capture Lesson

Record a lesson learned so future sessions can avoid the same mistake.

## When to Use

- After a user correction ("that's wrong, do X instead")
- After a verification failure is diagnosed and fixed
- After discovering a non-obvious codebase pattern
- After any re-plan due to a flawed approach

## Step 1: Identify the Lesson

From the current context, extract:
1. **What happened** — the mistake, correction, or discovery
2. **Root cause** — why the wrong approach was taken
3. **Preventive rule** — a concrete, actionable rule that prevents recurrence
4. **Scope** — which component or phase this applies to (or "general")

## Step 2: Append to Lessons File

Read `tasks/lessons.md` and append a new entry to the `## Lesson Log` section:

```markdown
### {date}: {Short descriptive title}
- **Trigger**: {What happened — be specific}
- **Root cause**: {Why it happened}
- **Rule**: {One-sentence rule, imperative form}
- **Applies to**: {component name, phase, or "general"}
```

## Step 3: Update Rules Index

Add the new rule to the `## Rules Index` section as a bullet point:
```markdown
- [{scope}] {Rule text}
```

Keep rules concise. If a new rule supersedes an old one, replace the old rule.

## Step 4: Confirm

Output a brief confirmation: what lesson was captured and the rule added.

User input: $ARGUMENTS
