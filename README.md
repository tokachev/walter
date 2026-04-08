# Walter

Docker sandbox for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with network isolation, credential leak protection, built-in data investigation agent, and a spec-driven development workflow.

## Why

Claude Code gets full access to files and the terminal. Walter wraps it in a container with three layers of protection:

| Layer | What it does | Protects against |
|-------|-------------|-----------------|
| **Docker** | Filesystem isolation | Access to host credentials (gcloud, aws, ssh) |
| **iptables** | Only `api.anthropic.com` allowed; IPv6 blocked | Outbound requests (boto3, gcloud SDK, curl, data exfiltration) |
| **credential-guard** | PreToolUse hook scans 40+ secret patterns | Secrets being written to project files |

## Features

- **Interactive / prompt modes** — Claude Code inside the sandbox, one-shot or REPL
- **Plan Executor** — task-by-task execution from a markdown plan, each task in a fresh `claude -p` session
- **Code Review** — 3-phase post-execution review (5 parallel agents → external Codex peer review → final verdict)
- **SDD** — spec-driven development state machine (`INIT → DISCUSSING → PLANNED → EXECUTING → VERIFYING → PHASE_COMPLETE → ARCHIVED`) with dual-model planning (Claude + Codex)
- **Autoresearch** — autonomous iterative improvement loop: each cycle a fresh agent modifies a file, runs an eval, keeps or discards based on a metric
- **Data Detective** — autonomous agent for investigating data anomalies (BigQuery + Snowflake)
- **MCP servers** — read-only Snowflake, read/write BigQuery (restricted to a single dataset), Data Detective
- **Auto-memory sharing** — Walter and host Claude Code CLI share the same project memory dir

## Quick start

```bash
# 1. Clone the repository
git clone <repo-url> walter && cd walter

# 2. Make scripts executable
chmod +x walter network-lock.sh plan-executor.sh hooks/*.sh hooks/*.py 2>/dev/null || true

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

# Allow extra domains (pip, npm, etc.)
./walter -a "pypi.org,files.pythonhosted.org" -d ./my-project

# Mount host gcloud ADC for BigQuery (no SA key needed)
./walter --gcloud -d ./my-project

# Execute a markdown plan
./walter --plan docs/plans/my-plan.md -d ./my-project

# Plan + code review pipeline
./walter --plan my-plan.md --review -d ./my-project

# Rebuild image
./walter --build -d ./my-project
```

### Options

| Flag | Description |
|------|-------------|
| `-d, --dir <path>` | Project directory (default: current) |
| `-a, --allow <domains>` | Extra domains, comma-separated |
| `--snowflake-key <path>` | Snowflake private key PEM file |
| `--bq-credentials <path>` | BigQuery service account JSON key file |
| `--bq-mcp-config <path>` | BigQuery MCP config JSON file |
| `--gcloud` | Mount host gcloud ADC (no SA key needed) |
| `--plan <file>` | Markdown plan file to execute |
| `--plan-max-iter <n>` | Max iterations for plan execution (default: 600) |
| `--plan-retries <n>` | Retry count per task (default: 2) |
| `--review` | Run plan then review |
| `--review-only` | Skip plan execution; run review only |
| `--build` | Rebuild Docker image before running |

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Docker container                                    │
│                                                      │
│  ┌─ network-lock.sh (entrypoint) ────────────────┐  │
│  │ iptables: ALLOW api.anthropic.com:443         │  │
│  │ ip6tables: DROP ALL                            │  │
│  │ Background DNS refresh every 5 min            │  │
│  └───────────────────────────────────────────────┘  │
│                                                      │
│  ┌─ Claude Code ─────────────────────────────────┐  │
│  │  PreToolUse hooks:                             │  │
│  │    credential-guard.py (Write, Edit, Bash)     │  │
│  │                                                │  │
│  │  MCP servers:                                  │  │
│  │    snowflake-readonly                          │  │
│  │    bigquery (read + write to one dataset)     │  │
│  │    data-detective (autonomous investigation)  │  │
│  │                                                │  │
│  │  SDD / plan-executor / autoresearch / review  │  │
│  └───────────────────────────────────────────────┘  │
│                                                      │
│  /workspace      ← project dir (rw)                 │
│  NO: gcloud, aws, ssh, host filesystem              │
└─────────────────────────────────────────────────────┘
```

## Project structure

```
walter/
├── walter                  # Main launcher (Docker orchestration)
├── network-lock.sh         # Network firewall + MCP registration (entrypoint)
├── plan-executor.sh        # Markdown plan executor
├── autoresearch.sh         # Iterative improvement loop
├── autoresearch-lib.sh     # Autoresearch helpers
├── Dockerfile
├── .env                    # Auth token (not in git)
│
├── hooks/                  # Native Claude Code hooks
│   ├── settings.json       # Hook configuration
│   ├── credential-guard.py # PreToolUse secret scanner (40+ patterns)
│   └── statusline-command.sh
│
├── sdd/                    # Spec-driven development workflow
│   ├── commands/           # /sdd:new-project, plan-phase, execute-phase, ...
│   └── agents/             # codebase-researcher, walter-planner, qa-validator, ...
│
├── detective/              # Data Detective — anomaly investigation agent
│   ├── detective_core.py
│   ├── mcp_server.py
│   └── connectors.py
│
├── mcp/                    # MCP servers
│   ├── sql_utils.py
│   ├── snowflake-readonly.py
│   └── bigquery/server.py  # BigQuery MCP (read + restricted write)
│
├── review/                 # 3-phase code review pipeline
│   ├── review-executor.sh
│   ├── agents/             # implementation, quality, testing, docs, simplification
│   └── prompts/
│
├── autoresearch/examples/  # generic-metric.sh, pytest-score.sh, sql-time.sh
│
├── commands/               # Slash commands
│   ├── autoresearch.md
│   ├── review.md
│   └── peer-review.md
│
├── tasks/lessons.md        # Persistent lessons captured across sessions
└── docs/plans/TEMPLATE.md  # Plan template
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
| Credential guard false positive | Adjust patterns in `hooks/credential-guard.py` |

## License

MIT
