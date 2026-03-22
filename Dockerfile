FROM node:22-slim

RUN apt-get update && apt-get install -y \
    git python3 python3-pip jq curl dnsutils \
    iptables iproute2 libcap2-bin gosu \
    && rm -rf /var/lib/apt/lists/*

# Reuse existing 'node' user (UID 1000) for running Claude Code
RUN usermod -d /opt/claude-home node

RUN npm install -g @anthropic-ai/claude-code @openai/codex

ENV PIP_DEFAULT_TIMEOUT=120 PIP_RETRIES=3

RUN pip install --break-system-packages chromadb rank_bm25 networkx pytest

# MCP server: read-only Snowflake access
COPY mcp/ /opt/mcp/
RUN pip install --break-system-packages -r /opt/mcp/requirements.txt

# MCP server: BigQuery read/write access
RUN pip install --break-system-packages -r /opt/mcp/bigquery/requirements.txt

# Data Detective: autonomous data anomaly investigation agent
COPY detective/ /opt/detective/
RUN pip install --break-system-packages -r /opt/detective/requirements.txt

ENV HOME=/opt/claude-home
ENV DISABLE_AUTOUPDATER=1
RUN mkdir -p $HOME $HOME/.codex

# Pre-configure user state to skip onboarding/login screen
# Claude Code reads from $HOME/.claude.json (NOT $HOME/.claude/settings.json)
RUN echo '{"theme":"dark","hasCompletedOnboarding":true}' > $HOME/.claude.json

# Pre-download ChromaDB embedding model (79MB) so it works offline
RUN python3 -c "import chromadb; c=chromadb.Client(); col=c.create_collection('warmup'); col.add(documents=['warmup'],ids=['1']); c.delete_collection('warmup'); print('Model cached')"

# Native hooks: credential-guard scanner + hook script
COPY hooks/ /opt/hooks/
RUN chmod +x /opt/hooks/credential-guard.sh /opt/hooks/scan-credentials.sh /opt/hooks/review-plan.sh /opt/hooks/statusline-command.sh /opt/hooks/inject-temporal-context.sh \
    && ln -s /opt/hooks/review-plan.sh /usr/local/bin/review-plan

# Guardrails: audit log, circuit breaker, cost tracker, SQL guard
COPY guardrails/ /opt/guardrails/
RUN chmod +x /opt/guardrails/hook.sh
RUN mkdir -p /var/log/walter && chown node:node /var/log/walter

# Plannotator: upstream binary for plan review UI (pre-compiled, self-contained)
ARG PLANNOTATOR_VERSION=0.13.0
ARG TARGETARCH
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "x64") && \
    curl -fsSL -o /usr/local/bin/plannotator \
    "https://github.com/backnotprop/plannotator/releases/download/v${PLANNOTATOR_VERSION}/plannotator-linux-${ARCH}" \
    && chmod +x /usr/local/bin/plannotator

# Plan executor: sequential task runner for markdown plans
COPY plan-executor.sh /opt/plan-executor.sh
RUN chmod +x /opt/plan-executor.sh

# Dashboard: real-time web UI for plan execution monitoring
COPY dashboard/ /opt/dashboard/

# Review executor: post-plan code review
COPY review/ /opt/review/
RUN chmod +x /opt/review/review-executor.sh

# SDD: commands and agents for spec-driven development workflow
COPY sdd/commands/ /opt/sdd/commands/
COPY sdd/agents/ /opt/sdd/agents/

# Install hooks configuration into Claude Code's global settings
RUN mkdir -p $HOME/.claude \
    && cp /opt/hooks/settings.json $HOME/.claude/settings.json

# Install detective agent markdown for Claude Code
RUN mkdir -p $HOME/.claude/agents \
    && cp /opt/detective/data-detective.md $HOME/.claude/agents/data-detective.md

# Install SDD commands and agents into Claude Code's config
RUN mkdir -p $HOME/.claude/commands/sdd \
    && cp /opt/sdd/commands/*.md $HOME/.claude/commands/sdd/ \
    && cp /opt/sdd/agents/*.md $HOME/.claude/agents/

# Install peer-review command
COPY commands/ /opt/commands/
RUN mkdir -p $HOME/.claude/commands \
    && cp /opt/commands/*.md $HOME/.claude/commands/

COPY network-lock.sh /usr/local/bin/network-lock
RUN chmod +x /usr/local/bin/network-lock

RUN git config --global user.name "walter" \
    && git config --global user.email "walter@local" \
    && git config --global init.defaultBranch main

# Symlink memory_tool so ~/memory_tool → /opt/memory_tool
RUN ln -s /opt/memory_tool $HOME/memory_tool

# Give non-root user ownership of its home directory
RUN chown -R node:node /opt/claude-home

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/network-lock"]