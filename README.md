# Walter

Docker sandbox for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with network isolation, credential leak protection, cost guardrails, multi-agent code review, and Spec-Driven Development workflows.

## Why

Claude Code gets full access to files and the terminal. Walter wraps it in a container with three layers of protection:

| Layer | What it does | Protects against |
|-------|-------------|-----------------|
| **Docker** | Filesystem isolation | Access to host credentials (gcloud, aws, ssh) |
| **iptables** | Only api.anthropic.com allowed | Outbound requests (boto3, gcloud SDK, curl, data exfiltration) |
| **credential-guard** | PreToolUse hooks scan 40+ secret patterns | Secrets being written to project files |
| **Guardrails** | Audit log, circuit breaker, cost tracker | Runaway loops, budget overruns |

## Features

- **Interactive mode** — Claude Code inside the sandbox, everything works as usual
- **Prompt mode** — pass a task in a single command
- **Plan Executor** — sequential task execution from a markdown plan
- **Code Review** — 3-phase automated review: 5 parallel agents → Codex peer review → 2 final agents
- **SDD (Spec-Driven Development)** — full workflow with 13 slash commands and 7 agents (state machine: INIT → DISCUSSING → PLANNED → EXECUTING → VERIFYING → ARCHIVED)
- **Data Detective** — autonomous agent for investigating data anomalies (BigQuery + Snowflake)
- **MCP servers** — read-only Snowflake, read/write BigQuery (restricted to a single dataset)
- **Dashboard** — real-time session monitoring web UI (`walter dashboard`), runs on the host
- **Plannotator** — web UI for reviewing and approving plans (upstream binary, dynamic port)
- **Guardrails** — always-on: JSONL audit log, circuit breaker (loop detection), cost tracker (per-run budget)

## Quick start

```bash
# 1. Clone the repository
git clone <repo-url> walter && cd walter

# 2. Make scripts executable
chmod +x walter network-lock.sh hooks/*.sh

# 3. Add auth token
echo "CLAUDE_CODE_OAUTH_TOKEN=your-token" > .env

# 4. Build the image
docker build -t walter:latest .

# 5. Run
./walter -d ./my-project
```

## Usage

```bash
# Interactive mode
./walter -d ./my-project

# With a prompt
./walter -d ./my-project "Add incremental loading for the events table"

# With memory tool
./walter -m ~/memory_tool -d ./my-project

# Allow extra domains (pip, npm, etc.)
./walter -a "pypi.org,files.pythonhosted.org" -d ./my-project

# Execute a plan
./walter --plan docs/plans/my-plan.md -d ./my-project

# Plan + code review
./walter --plan docs/plans/my-plan.md --review -d ./my-project

# Code review only (skip plan execution)
./walter --review-only -d ./my-project

# With cost budget
./walter --cost-budget 10 --plan my-plan.md -d ./my-project

# Using host gcloud ADC for BigQuery
./walter --gcloud -d ./my-project

# Real-time dashboard
./walter dashboard
./walter dashboard --port 8080

# Rebuild image
./walter --build -d ./my-project
```

### Options

| Flag | Description |
|------|-------------|
| `-d, --dir <path>` | Project directory (default: current) |
| `-m, --memory <path>` | Memory tool directory to mount |
| `-a, --allow <domains>` | Extra domains, comma-separated |
| `--snowflake-key <path>` | Snowflake private key PEM file |
| `--bq-credentials <path>` | BigQuery service account JSON key file |
| `--bq-mcp-config <path>` | BigQuery MCP config JSON file |
| `--gcloud` | Mount host gcloud ADC for BigQuery (no SA key needed) |
| `--plan <file>` | Markdown plan file to execute |
| `--plan-max-iter <n>` | Max iterations for plan execution (default: 600) |
| `--plan-retries <n>` | Retry count per task (default: 2) |
| `--cost-budget <usd>` | Max cost per run in USD (default: 5) |
| `--review` | Run plan then code review (requires `--plan`) |
| `--review-only` | Skip plan execution, run review only |
| `--build` | Rebuild Docker image before running |

| Subcommand | Description |
|------------|-------------|
| `dashboard` | Start the web dashboard (default port: 19433) |
| `dashboard --port <n>` | Custom dashboard port |

## Architecture

```
┌──────────── HOST ─────────────────────────────────────┐
│                                                        │
│  walter (launcher)                                     │
│  dashboard (Node.js, port 19433)                       │
│     └── reads ~/.walter/sessions/                      │
│                                                        │
│  ┌──────── Docker container ──────────────────────┐    │
│  │                                                 │    │
│  │  network-lock.sh (iptables firewall)            │    │
│  │    ALLOW api.anthropic.com:443 + allowlist      │    │
│  │    DROP all IPv6                                │    │
│  │    Background DNS refresh every 5 min           │    │
│  │                                                 │    │
│  │  Claude Code                                    │    │
│  │  ├── Hooks (PreToolUse)                         │    │
│  │  │   ├── guardrails/* (audit, circuit breaker,  │    │
│  │  │   │   cost tracker) — runs on every call     │    │
│  │  │   ├── credential-guard (Write, Edit, Bash)   │    │
│  │  │   ├── large-file-guard (Read)                │    │
│  │  │   └── memory-project-validator (Bash)        │    │
│  │  ├── Hooks (PostToolUse)                        │    │
│  │  │   └── duplicate-checker (Edit, Write)        │    │
│  │  ├── Hooks (SessionStart)                       │    │
│  │  │   └── inject-temporal-context                │    │
│  │  │                                              │    │
│  │  ├── MCP servers                                │    │
│  │  │   ├── snowflake-readonly                     │    │
│  │  │   ├── bigquery                               │    │
│  │  │   └── data-detective                         │    │
│  │  │                                              │    │
│  │  ├── SDD commands (/sdd:new-project, etc.)      │    │
│  │  ├── Review system (3-phase, 7 agents)          │    │
│  │  └── Plan executor                              │    │
│  │                                                 │    │
│  │  /workspace ← project directory (rw)            │    │
│  │  NO: gcloud, aws, ssh, host filesystem          │    │
│  └─────────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────┘
```

## Project structure

```
walter/
├── walter                    # Main launcher (Docker orchestration)
├── network-lock.sh           # Network firewall (container entrypoint)
├── plan-executor.sh          # Markdown plan executor
├── Dockerfile
├── CLAUDE.md                 # Claude Code project guidance
├── .env                      # Auth token (not in git)
│
├── hooks/                    # Claude Code native hooks
│   ├── settings.json         # Hook + statusline configuration
│   ├── credential-guard.sh   # PreToolUse: secret scanner
│   ├── scan-credentials.sh   # 40+ regex patterns for secrets
│   ├── inject-temporal-context.sh  # SessionStart: date/time
│   ├── large-file-guard.sh   # PreToolUse Read: block oversized files
│   ├── duplicate-checker.sh  # PostToolUse Edit/Write: detect duplication
│   ├── memory-project-validator.sh # PreToolUse Bash: memory tool checks
│   ├── review-plan.sh        # Plan review hook
│   └── statusline-command.sh # Status bar display
│
├── guardrails/               # Always-on safety subsystem
│   ├── hook.sh               # PreToolUse dispatcher (every tool call)
│   ├── hook_check.py         # Python orchestrator
│   ├── audit.py              # JSONL audit log
│   ├── circuit_breaker.py    # Loop detection (50 calls / 120s)
│   ├── cost_tracker.py       # Per-run cost budget
│   └── correction_detector.py # Detects repeated corrections
│
├── review/                   # Multi-agent code review
│   ├── review-executor.sh    # 3-phase orchestrator
│   ├── agents/               # Phase 1: implementation, quality, testing,
│   │                         #   simplification, docs (5 parallel)
│   │                         # Phase 3: final-impl, final-quality (2 final)
│   └── prompts/              # Evaluation + Codex peer review prompts
│
├── sdd/                      # Spec-Driven Development workflow
│   ├── commands/             # 13 slash commands: new-project, onboard,
│   │                         #   map-codebase, discuss-phase, plan-phase,
│   │                         #   execute-phase, verify-work, capture-lesson,
│   │                         #   sync-specs, status, quick, autopilot, archive
│   └── agents/               # 7 agents: walter-planner, plan-coordinator,
│                              #   plan-executor, codebase-researcher,
│                              #   qa-validator, elegance-reviewer, sdd-debugger
│
├── commands/                 # Standalone slash commands
│   ├── review.md             # /review
│   ├── review-plan.md        # /review-plan
│   └── peer-review.md        # /peer-review (Codex)
│
├── dashboard/                # Real-time monitoring (host-side)
│   ├── server.js             # Node.js HTTP + SSE server
│   └── ui.html               # Web UI (3-column layout)
│
├── detective/                # Data Detective agent
│   ├── detective_core.py     # Investigation loop + SQL executor
│   ├── mcp_server.py         # MCP server wrapper
│   ├── connectors.py         # BigQuery and Snowflake connectors
│   └── data-detective.md     # Agent definition
│
├── mcp/                      # MCP servers
│   ├── sql_utils.py          # Shared SQL utilities
│   ├── snowflake-readonly.py # Read-only Snowflake MCP
│   └── bigquery/
│       └── server.py         # BigQuery MCP (read + restricted write)
│
├── tasks/
│   └── lessons.md            # Persistent lessons from corrections
│
└── docs/plans/
    └── TEMPLATE.md           # Plan template
```

## Data Detective setup

To use Data Detective, add these variables to your project's `.env`:

```bash
# BigQuery
BQ_PROJECT=my-gcp-project
BQ_CREDENTIALS_PATH=/path/to/service-account.json

# Snowflake
SNOWFLAKE_ACCOUNT=myaccount.us-central1.gcp
SNOWFLAKE_USER=myuser
SNOWFLAKE_PRIVATE_KEY_PATH=/path/to/snowflake_key.pem
SNOWFLAKE_WAREHOUSE=COMPUTE_WH
SNOWFLAKE_DATABASE=MY_DB
SNOWFLAKE_ROLE=ANALYST

# Agent settings (optional)
DETECTIVE_MODEL=claude-sonnet-4-20250514
DETECTIVE_MAX_ITER=15
```

## Requirements

- Docker Desktop (macOS / Linux / Windows WSL)
- Claude Code auth token (OAuth or API key)

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `api.anthropic.com — FAILED` on startup | DNS not working in container: `docker run --rm alpine nslookup api.anthropic.com` |
| Claude Code not authorized | Check `CLAUDE_CODE_OAUTH_TOKEN` in `.env` or `ANTHROPIC_API_KEY` |
| Task stuck | Ctrl+C stops the container; changes are preserved in the project directory |
| Credential guard false positive | Add pattern to `ALLOWLIST_PATTERNS` in `hooks/scan-credentials.sh` |
| Cost budget exceeded | Increase with `--cost-budget <usd>` (default: $5) |
| Circuit breaker triggered | Tool called >50 times in 120s; adjust via `WALTER_CB_THRESHOLD` / `WALTER_CB_WINDOW` |

## License

MIT
