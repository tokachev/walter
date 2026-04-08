---
description: "Use after execution to sync requirement changes. Trigger: 'sync specs', 'синхронизируй требования', 'merge deltas'"
allowed-tools: Read, Write, Edit, Glob, Grep
---

# SDD: Sync Specs

Merge requirement changes (delta specs) accumulated during execution back into the main REQUIREMENTS.md.

## Step 1: Load Sources

1. Read `.planning/REQUIREMENTS.md` (current source of truth)
2. Read `.planning/REQUIREMENTS-CHANGELOG.md` (pending deltas)
3. If changelog doesn't exist or has no phase deltas, report "No delta specs to sync" and stop
4. Identify unsynced phase deltas (entries without `✓ Synced` marker)

## Step 2: Preview Changes

Present to the user a summary of all pending changes:

### Requirements to ADD
- List each new requirement with the source phase

### Requirements to MODIFY
- Show before → after for each modification

### Requirements to REMOVE
- List each removal with rationale from the changelog

If no unsynced changes exist, report "All delta specs already synced" and stop.

## Step 3: Apply Changes (with confirmation)

Ask the user to confirm:
> "Apply these requirement changes to REQUIREMENTS.md? (You can also choose to apply selectively.)"

- If confirmed: apply all ADDED/MODIFIED/REMOVED changes to `.planning/REQUIREMENTS.md`
- If selective: ask which categories to apply
- Place ADDED requirements in the appropriate section (Must Have / Should Have)
- For MODIFIED: update the original requirement text in place
- For REMOVED: delete the requirement and add it to an `## Out of Scope` section if not already there

After applying, mark each synced phase in REQUIREMENTS-CHANGELOG.md:
```
## Phase {N}: {Phase Name} ({ISO date}) ✓ Synced {ISO timestamp}
```

## Step 4: Report

- Show the updated REQUIREMENTS.md section counts (Must Have: N, Should Have: N, Out of Scope: N)
- Note any changes that were skipped
- Suggest: `/sdd:archive` to archive completed phases

User input: $ARGUMENTS
