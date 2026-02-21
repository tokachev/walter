# walter — Setup & Usage Guide

## What is this

Docker sandbox for Claude Code with:
- Network firewall (only api.anthropic.com allowed, everything else blocked)
- Credential-guard via native hooks (blocks secrets from being written to files)
- No access to host credentials (gcloud, aws, ssh)

Claude Code runs directly inside the container — all orchestration (planning, execution, review) is handled by Claude Code's built-in agents.

---

## Requirements

- Docker Desktop (macOS/Linux/Windows WSL)
- Claude Code auth token (OAuth or API key)

---

## Setup

### 1. Clone or copy files

```
walter/
├── walter                    # Docker launcher (CLI command)
├── network-lock.sh           # Network firewall (entrypoint)
├── Dockerfile                # Container image
├── .env                      # Auth token
├── hooks/                    # Credential-guard (native Claude Code hooks)
│   ├── credential-guard.sh   # PreToolUse hook handler
│   ├── scan-credentials.sh   # Credential scanner (40+ regex patterns)
│   └── settings.json         # Claude Code hooks configuration
├── docs/
│   └── plans/
│       └── TEMPLATE.md       # Plan template
└── SETUP.md
```

### 2. Make scripts executable

```bash
chmod +x walter network-lock.sh
chmod +x hooks/credential-guard.sh hooks/scan-credentials.sh
```

### 3. Add auth token

Create `.env` in the walter directory:

```bash
CLAUDE_CODE_OAUTH_TOKEN=your-token-here
```

Or set `ANTHROPIC_API_KEY` as an environment variable.

### 4. Build Docker image

```bash
docker build -t walter:latest .
```

First build downloads ~2GB (Node.js, Claude Code, ChromaDB). Subsequent builds are fast.

### 5. Add alias (optional)

```bash
# Add to ~/.bashrc or ~/.zshrc:
alias walter='~/walter/walter'
```

---

## Usage

### Interactive mode

```bash
./walter -d ./my-project
```

Starts Claude Code interactively inside the container. You can chat, use slash commands, built-in agents — everything works as normal, but inside the sandbox.

### With a prompt

```bash
./walter -d ./my-project "Add incremental loading for events table"
```

Passes the prompt directly to `claude` inside the container.

### With memory tool

```bash
./walter -m ~/memory_tool -d ./my-project
```

### Allow extra domains

```bash
./walter -a "pypi.org,files.pythonhosted.org" -d ./my-project
```

### Force rebuild

```bash
./walter --build -d ./my-project
```

---

## How it works

```
┌──────────────────────────────────────────────────┐
│  Docker container                                 │
│                                                   │
│  ┌─ network-lock.sh ──────────────────────────┐  │
│  │ iptables: ALLOW api.anthropic.com:443      │  │
│  │ ip6tables: DROP ALL                         │  │
│  │ Background IP refresh every 5 min           │  │
│  └────────────────────────────────────────────┘  │
│                                                   │
│  ┌─ claude ──────────────────────────────────┐   │
│  │                                            │   │
│  │  Claude Code with built-in agents:         │   │
│  │    orchestrator, task-planner,             │   │
│  │    plan-executor, code-review-strict,      │   │
│  │    qa-validator                             │   │
│  │                                            │   │
│  │  Native hooks (settings.json):             │   │
│  │    PreToolUse → credential-guard.sh        │   │
│  │    (Write, Edit, Bash matchers)            │   │
│  │                                            │   │
│  └────────────────────────────────────────────┘  │
│                                                   │
│  /workspace  ← project directory (rw)            │
│                                                   │
│  NO: gcloud, aws, ssh, host filesystem           │
└──────────────────────────────────────────────────┘
```

---

## Security — 3 layers

| Layer | What it does | Protects against |
|-------|-------------|-----------------|
| **Docker** | Filesystem isolation | Host credentials (gcloud/aws/ssh) |
| **iptables** | Only api.anthropic.com allowed | Outbound requests (boto3, gcloud SDK, curl) |
| **credential-guard** | Native PreToolUse hooks scan for secrets | Secrets written to project files |

---

## Troubleshooting

### "api.anthropic.com — FAILED" at startup

DNS not working inside container:

```bash
docker run --rm alpine nslookup api.anthropic.com
```

### Claude Code not authorized

Add `CLAUDE_CODE_OAUTH_TOKEN` to `.env` file, or set `ANTHROPIC_API_KEY` env var.

### Task stuck

Ctrl+C stops the container. All changes remain in your project directory:

```bash
git status
git diff
```

### Credential scan false positive

Add pattern to `ALLOWLIST_PATTERNS` in `hooks/scan-credentials.sh`.
