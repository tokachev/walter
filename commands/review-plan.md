---
description: "Open a plan file in plannotator web UI for review and annotation"
allowed-tools: Bash, Read, Glob, Edit
---

# Review Plan

Open a markdown plan file in plannotator's browser UI for review.

## Input

`$ARGUMENTS` — path to a plan file. If empty, auto-select the latest plan from `.planning/phases/`.

## Instructions

1. Read `PLANNOTATOR_PORT` env var via `echo $PLANNOTATOR_PORT`.

2. Run `review-plan $ARGUMENTS` via Bash **in background** mode. This starts plannotator's web server and blocks until the user submits a decision.

3. Tell the user: "Plan is open for review at http://localhost:{PORT}. Review it in the browser, leave annotations, then click Approve or Deny."

4. When the background task completes, read its output. The output will say:
   - `APPROVED: <file>` — user approved the plan, optionally with feedback
   - `DENIED: <file>` — user rejected the plan, with feedback explaining why

5. If there is feedback, present it to the user and ask how they want to proceed. If the plan was approved with no feedback, confirm and move on.
