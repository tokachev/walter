# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Walter

Docker sandbox for running Claude Code with network isolation (iptables), credential leak protection (PreToolUse hooks), cost guardrails, and built-in agents for data investigation. Everything runs inside a container — no host access to gcloud/aws/ssh.

## Build and Run

```bash
# Build the Docker image
docker build -t walter:latest .

# Interactive mode
./walter -d ./my-project

# With a prompt
./walter -d ./my-project "Add incremental loading"

# Execute a plan
./walter --plan docs/plans/my-plan.md -d ./my-project

# Plan + code review
./walter --plan my-plan.md --review -d ./my-project

# Allow extra network domains
./walter -a "pypi.org,files.pythonhosted.org" -d ./my-project

# Real-time dashboard (runs on host, monitors all sessions)
./walter dashboard
./walter dashboard --port 8080
```

## Testing

No test framework. The only test is a manual smoke test for the BigQuery MCP server:
```bash
BQ_MCP_TEST_CONFIG=/path/to/config.json python3 mcp/bigquery/test_smoke.py
```

Validate shell scripts and dashboard:
```bash
bash -n walter
bash -n network-lock.sh
bash -n plan-executor.sh
bash -n review/review-executor.sh
node --check dashboard/server.js
```

## Architecture

### Execution layers (outer → inner)

1. **`walter`** (bash) — Host-side Docker orchestrator. Parses flags, resolves credentials/mounts, assembles `docker run`. Sources auth from `./walter/.env`, project credentials from `<project>/.env`. Creates per-session log directories at `~/.walter/sessions/<project>-<timestamp>/` and mounts them into the container as `/var/log/walter/`. Also provides `walter dashboard` subcommand (host-side Node.js, no Docker).

2. **`network-lock.sh`** (container entrypoint) — iptables firewall. Only `api.anthropic.com` allowed by default; extra domains via `--allowlist`. IPv6 fully blocked. Background DNS refresh every 5 min.

3. **Claude Code** runs inside the container with:
   - **PreToolUse hooks** (`hooks/settings.json` → installed to `$HOME/.claude/settings.json`):
     - `guardrails/hook.sh` (matcher: `.*`) — audit log + circuit breaker + cost budget check
     - `hooks/credential-guard.sh` (matchers: Write, Edit, Bash) — scans content for 40+ secret patterns via `scan-credentials.sh`
   - **PermissionRequest hook**: upstream `plannotator` binary (v0.13.0) on `ExitPlanMode` — browser-based plan approval UI with themes, diff views, annotations, Mermaid diagrams. Each session gets a dynamic port (base `WALTER_PLANNOTATOR_PORT`, default 19440) published to the host via `-p`.

### Guardrails subsystem (`guardrails/`)

All four modules are called on every tool invocation via `hook.sh` → `hook_check.py`:
- **audit.py** — append-only JSONL log at `/var/log/walter/audit.jsonl`
- **circuit_breaker.py** — blocks a tool if called >50 times in 120s (configurable via `WALTER_CB_THRESHOLD`, `WALTER_CB_WINDOW`)
- **cost_tracker.py** — estimates token cost, blocks when `WALTER_COST_BUDGET` (default $5) is exceeded
- **sql_guard_check.py** (in `detective/`) — bridges to `mcp/sql_utils.py:check_sql_safety()` for detective queries

### MCP servers

- **snowflake-readonly** (`mcp/snowflake-readonly.py`) — FastMCP, key-pair auth. Tools: `query`, `list_schemas`, `list_tables`, `describe_table`. Only SELECT/SHOW/DESCRIBE/WITH/EXPLAIN allowed.
- **bigquery** (`mcp/bigquery/server.py`) — FastMCP, SA key or ADC auth. Read tools + write restricted to a single configured dataset. Config via JSON file (`BQ_MCP_CONFIG_PATH`).
- **data-detective** (`detective/mcp_server.py`) — wraps `detective_core.py`. Autonomous investigation agent that uses `claude -p` subprocess calls (inherits container's OAuth).
- Shared SQL utilities in `mcp/sql_utils.py` (comment stripping, safety checks, markdown formatting).

### Plan execution (`plan-executor.sh`)

Parses `### Task N:` headers from markdown plans. Each task runs in a fresh `claude -p` session. Supports `[WAIT]` items (manual gates), retries, wave filtering, and multi-plan directory mode.

### Code review (`review/review-executor.sh`)

3-phase review after plan execution:
- Phase 1: 5 parallel agents (implementation, quality, testing, docs, simplification) → evaluation
- Phase 2: External review via OpenAI Codex (`/peer-review`)
- Phase 3: 2 final agents (final-impl, final-quality) → verdict

Agent definitions in `review/agents/*.md`, evaluation prompts in `review/prompts/*.md`.

### Dashboard (`dashboard/`)

Host-side real-time monitoring UI. Runs via `walter dashboard` (NOT inside the container).
- **`dashboard/server.js`** — Node.js HTTP + SSE server. Watches `~/.walter/sessions/*/` for all active/historical sessions. Tails `audit.jsonl`, `progress.jsonl`, polls `cost.json`. Auto-discovers new sessions every 2s.
- **`dashboard/ui.html`** — Single HTML file with embedded CSS/JS. Three-column layout: session list (left), log stream (center), plan + metrics (right). SSE via EventSource, per-session color coding.
- **Session structure** (`~/.walter/sessions/<id>/`): `session.json` (metadata), `audit.jsonl`, `progress.jsonl`, `cost.json`, `done` (written by `walter` on container exit).
- **`plan-executor.sh`** writes structured progress events to `/var/log/walter/progress.jsonl` (plan_start, task_start, task_end, task_failed, plan_complete).

### GSD workflow (`gsd/`)

Spec-driven development state machine: INIT → DISCUSSING → PLANNED → EXECUTING → VERIFYING → PHASE_COMPLETE. Commands in `gsd/commands/*.md`, agents in `gsd/agents/*.md`. State tracked in `.planning/`.

Planning flow is dual-model by design:
- research uses Claude + Codex in parallel and writes merged briefs under `.claude/research/`
- plan synthesis goes through `gsd/agents/plan-coordinator.md`, which compares independent Claude + Codex drafts and writes the final plan
- Walter runtime merges repo-owned GSD commands/agents over host `~/.claude` duplicates so container behavior stays aligned with the repo
- repo-owned GSD agents now include `codebase-researcher`, `walter-planner`, `plan-executor`, `qa-validator`, `plan-coordinator`, `gsd-debugger`, and `elegance-reviewer`
- Self-improvement loop: `tasks/lessons.md` stores persistent lessons and rules; `gsd/commands/capture-lesson.md` appends new lessons after corrections or failures; `autopilot.md` loads rules at session start; `execute-phase.md` captures lessons after each phase
- Elegance pause: `plan-executor.md` includes an elegance check before non-trivial tasks; `elegance-reviewer` agent can be spawned for deeper review between plan and execute phases
- Results documentation: `execute-phase.md` writes `.planning/phases/phase-{N}-RESULTS.md` after each phase with summary, changes, decisions, and validation status

## Key conventions

- **Auth flow**: Walter's own `.env` has `CLAUDE_CODE_OAUTH_TOKEN`. Project credentials (Snowflake, BigQuery, OpenAI) come from the project's `.env` via a safe parser (no `source`/`eval`).
- **Container paths**: project → `/workspace`, secrets → `/opt/secrets/`, MCP servers → `/opt/mcp/`, hooks → `/opt/hooks/`, guardrails → `/opt/guardrails/`, plannotator → `/usr/local/bin/plannotator`, session logs → `/var/log/walter/` (mounted from `~/.walter/sessions/<id>/`).
- **Fail-open**: Both credential guard and guardrails fail-open (scanner errors don't block operations).
- **Plan format**: Must use `### Task N: {title}` headers with `- [ ]` checklist items. Template at `docs/plans/TEMPLATE.md`.
- **All shell scripts** use `set -e` (or `set -euo pipefail`). The `walter` launcher is the main orchestration entry point — all Docker flags, mounts, and env vars are assembled there.
