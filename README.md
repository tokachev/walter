# Walter

Docker sandbox for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with network isolation, credential leak protection, and a built-in agent for investigating data anomalies.

## Why

Claude Code gets full access to files and the terminal. Walter wraps it in a container with three layers of protection:

| Layer | What it does | Protects against |
|-------|-------------|-----------------|
| **Docker** | Filesystem isolation | Access to host credentials (gcloud, aws, ssh) |
| **iptables** | Only api.anthropic.com allowed | Outbound requests (boto3, gcloud SDK, curl, data exfiltration) |
| **credential-guard** | PreToolUse hooks scan 40+ secret patterns | Secrets being written to project files |

## Features

- **Interactive mode** — Claude Code inside the sandbox, everything works as usual
- **Prompt mode** — pass a task in a single command
- **Plan Executor** — sequential task execution from a markdown plan
- **Data Detective** — autonomous agent for investigating data anomalies (BigQuery + Snowflake)
- **MCP servers** — read-only Snowflake, read/write BigQuery (restricted to a single dataset)
- **Plannotator** — web UI for reviewing and approving plans

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
| `--plan <file>` | Markdown plan file to execute |
| `--plan-max-iter <n>` | Max iterations for plan execution (default: 50) |
| `--plan-retries <n>` | Retry count per task (default: 2) |
| `--build` | Rebuild Docker image before running |

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Docker container                                    │
│                                                      │
│  ┌─ network-lock.sh ─────────────────────────────┐  │
│  │ iptables: ALLOW api.anthropic.com:443         │  │
│  │ ip6tables: DROP ALL                            │  │
│  │ Background IP refresh every 5 min             │  │
│  └───────────────────────────────────────────────┘  │
│                                                      │
│  ┌─ Claude Code ─────────────────────────────────┐  │
│  │  Hooks (PreToolUse):                           │  │
│  │    credential-guard.sh → scan-credentials.sh   │  │
│  │    (Write, Edit, Bash)                         │  │
│  │                                                │  │
│  │  MCP servers:                                  │  │
│  │    snowflake-readonly (query, list, describe)  │  │
│  │    bigquery (read + write to one dataset)      │  │
│  │                                                │  │
│  │  Agents:                                       │  │
│  │    Data Detective (anomaly investigation)      │  │
│  └───────────────────────────────────────────────┘  │
│                                                      │
│  /workspace  ← project directory (rw)               │
│  NO: gcloud, aws, ssh, host filesystem              │
└─────────────────────────────────────────────────────┘
```

## Project structure

```
walter/
├── walter                  # Main launcher (Docker orchestration)
├── network-lock.sh         # Network firewall (container entrypoint)
├── plan-executor.sh        # Markdown plan executor
├── Dockerfile
├── .env                    # Auth token (not in git)
│
├── hooks/                  # Credential guard (native Claude Code hooks)
│   ├── settings.json       # Hook configuration
│   ├── credential-guard.sh # PreToolUse handler
│   └── scan-credentials.sh # Secret scanner (40+ regex patterns)
│
├── detective/              # Data Detective — anomaly investigation agent
│   ├── detective_core.py   # Investigation loop + SQL executor
│   ├── mcp_server.py       # MCP server for Data Detective
│   ├── connectors.py       # BigQuery and Snowflake connectors
│   └── data-detective.md   # Agent definition for Claude Code
│
├── mcp/                    # MCP servers
│   ├── sql_utils.py        # Shared utilities (markdown tables, SQL validation)
│   ├── snowflake-readonly.py # Read-only Snowflake MCP
│   └── bigquery/
│       └── server.py       # BigQuery MCP (read + restricted write)
│
├── plannotator/            # Web UI for plan review
│   ├── server.js           # HTTP server
│   ├── ui.html             # UI
│   └── hook.sh             # Permission request hook
│
└── docs/plans/
    └── TEMPLATE.md         # Plan template
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

## License

MIT
