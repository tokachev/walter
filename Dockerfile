FROM node:22-slim

RUN apt-get update && apt-get install -y \
    git python3 python3-pip jq curl dnsutils \
    iptables iproute2 libcap2-bin gosu \
    && rm -rf /var/lib/apt/lists/*

# Reuse existing 'node' user (UID 1000) for running Claude Code
RUN usermod -d /opt/claude-home node

RUN npm install -g @anthropic-ai/claude-code

RUN pip install --break-system-packages chromadb rank_bm25 networkx

# MCP server: read-only Snowflake access
COPY mcp/ /opt/mcp/
RUN pip install --break-system-packages -r /opt/mcp/requirements.txt

# Data Detective: autonomous data anomaly investigation agent
COPY detective/ /opt/detective/
RUN pip install --break-system-packages -r /opt/detective/requirements.txt

ENV HOME=/opt/claude-home
ENV DISABLE_AUTOUPDATER=1
RUN mkdir -p $HOME

# Pre-configure user state to skip onboarding/login screen
# Claude Code reads from $HOME/.claude.json (NOT $HOME/.claude/settings.json)
RUN echo '{"theme":"dark","hasCompletedOnboarding":true}' > $HOME/.claude.json

# Pre-download ChromaDB embedding model (79MB) so it works offline
RUN python3 -c "import chromadb; c=chromadb.Client(); col=c.create_collection('warmup'); col.add(documents=['warmup'],ids=['1']); c.delete_collection('warmup'); print('Model cached')"

# Native hooks: credential-guard scanner + hook script
COPY hooks/ /opt/hooks/
RUN chmod +x /opt/hooks/credential-guard.sh /opt/hooks/scan-credentials.sh

# Plannotator: browser-based plan review UI
COPY plannotator/ /opt/plannotator/
RUN chmod +x /opt/plannotator/hook.sh

# Install hooks configuration into Claude Code's global settings
RUN mkdir -p $HOME/.claude \
    && cp /opt/hooks/settings.json $HOME/.claude/settings.json

# Install detective agent markdown for Claude Code
RUN mkdir -p $HOME/.claude/agents \
    && cp /opt/detective/data-detective.md $HOME/.claude/agents/data-detective.md

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