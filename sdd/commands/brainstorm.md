---
description: "Explore an idea through collaborative design before any implementation. Works standalone — no SDD project required."
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# Brainstorm

Turn ideas into fully formed designs through collaborative dialogue. Dual-model research (Claude + Codex) followed by iterative design refinement.

<HARD-GATE>
Do NOT write any code, scaffold any project, or take any implementation action until you have presented a design and the user has approved it. This applies to EVERY idea regardless of perceived simplicity.
</HARD-GATE>

## Anti-Pattern: "This Is Too Simple To Need A Design"

Every project goes through this process. A todo list, a single-function utility, a config change — all of them. "Simple" projects are where unexamined assumptions cause the most wasted work. The design can be short (a few sentences for truly simple projects), but you MUST present it and get approval.

## Step 1: Explore Project Context

Launch dual-model research in parallel to understand the codebase:

**Claude research** — run in background:
```
Agent(subagent_type="codebase-researcher", run_in_background=true, prompt="
Investigate the codebase for context relevant to: {$ARGUMENTS}.
Focus on:
- Existing patterns and conventions
- Files and modules that will be affected
- Dependencies and integration points
- Prior art — has something similar been built before?
Write findings to docs/designs/research-{topic-slug}.md
")
```

**Codex research** — run in parallel. First check `command -v codex`. If not found, skip and note degraded mode:
```bash
mkdir -p docs/designs
codex exec -s danger-full-access <<'CODEX_EOF' 2>&1 | tee docs/designs/research-{topic-slug}-codex.md
Investigate the codebase for context relevant to: {$ARGUMENTS}.
Focus on:
- Existing implementation patterns to follow
- Directly relevant files and modules
- Integration points and risks
Output structured markdown with concrete file references.
CODEX_EOF
```

After both complete, merge into `docs/designs/research-{topic-slug}.md`:
- Shared findings
- Claude-only insights
- Codex-only insights
- Any contradictions

If Codex is unavailable, continue with Claude-only research.

Present a **3-5 bullet summary** of key findings to the user.

## Step 2: Assess Scope

Before asking detailed questions, assess scope: if the request describes multiple independent subsystems (e.g., "build a platform with chat, file storage, billing, and analytics"), flag this immediately.

If the project is too large for a single spec, help the user decompose into sub-projects: what are the independent pieces, how do they relate, what order should they be built? Then brainstorm the first sub-project. Each sub-project gets its own `/sdd:brainstorm` cycle.

## Step 3: Ask Clarifying Questions

**CRITICAL**: Ask ONE question at a time using AskFollowupQuestion. Wait for the user's response before asking the next question. Do NOT batch multiple questions.

- Prefer multiple choice questions when possible
- Focus on understanding: purpose, constraints, success criteria
- If `$ARGUMENTS` already answers a question, skip it
- Stop asking when you have enough to propose approaches (typically 3-5 questions)

## Step 4: Propose 2-3 Approaches

Present 2-3 different approaches with trade-offs:
- Lead with your recommended option and explain why
- Present conversationally, not as a wall of text
- Include concrete trade-offs (complexity, performance, maintenance, etc.)

Wait for the user to choose or suggest a different direction.

## Step 5: Present Design Incrementally

Once you understand what you're building, present the design section by section. Scale each section to its complexity: a few sentences if straightforward, up to 200-300 words if nuanced.

Ask after each section whether it looks right so far. Cover as appropriate:
- Architecture overview
- Components and their responsibilities
- Data flow
- Error handling
- Testing strategy

**Design for isolation and clarity:**
- Break into smaller units with one clear purpose each
- Well-defined interfaces between units
- Each unit independently understandable and testable

**Working in existing codebases:**
- Follow existing patterns
- Where existing code has problems affecting this work, include targeted improvements
- Don't propose unrelated refactoring

## Step 6: Write Spec

Save the validated design to `docs/designs/YYYY-MM-DD-{topic-slug}-design.md`.

Commit the design document:
```bash
git add docs/designs/YYYY-MM-DD-{topic-slug}-design.md
git commit -m "docs: add design spec for {topic}"
```

## Step 7: Spec Review Loop

Dispatch the spec-reviewer agent:
```
Agent(subagent_type="spec-reviewer", prompt="
Review the spec at docs/designs/YYYY-MM-DD-{topic-slug}-design.md.
Check for: completeness, consistency, clarity, scope focus, YAGNI violations.
Output: Status (Approved/Issues Found), specific Issues, advisory Recommendations.
")
```

- If **Issues Found**: fix the issues, re-dispatch. Max 3 iterations.
- If still failing after 3 iterations, surface to the user for guidance.
- If **Approved**: proceed.

## Step 8: User Review Gate

> "Spec written and committed to `docs/designs/YYYY-MM-DD-{topic-slug}-design.md`. Please review it and let me know if you want to make any changes before we move to planning."

Wait for the user's response. If they request changes, make them and re-run the spec review loop.

## Step 9: Transition

Once the user approves the spec, suggest next steps:
- `/sdd:quick {topic}` — for small, focused tasks
- `/sdd:plan-phase` — for larger work within an SDD project

Do NOT automatically invoke any implementation command. Let the user decide.

## Key Principles

- **One question at a time** — don't overwhelm
- **Multiple choice preferred** — easier to answer
- **YAGNI ruthlessly** — cut unnecessary features from all designs
- **Explore alternatives** — always propose 2-3 approaches
- **Incremental validation** — present design, get approval before moving on
- **Be flexible** — go back and clarify when something doesn't make sense

User input: $ARGUMENTS
