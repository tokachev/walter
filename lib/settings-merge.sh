#!/usr/bin/env bash
# settings-merge.sh — settings.json merge + built-in agents/commands merge + runtime home logic
# Sourced by network-lock.sh. No set -e.

# ── Constants ────────────────────────────────────────────────
HOST_SETTINGS="/tmp/host-settings.json"
CONTAINER_SETTINGS="$HOME/.claude/settings.json"
AGENTS_DIR="$HOME/.claude/agents"
COMMANDS_DIR="$HOME/.claude/commands"
BUILTIN_AGENTS_DIR="/opt/detective"
BUILTIN_COMMANDS_DIR="/opt/sdd/commands"
BUILTIN_SDD_AGENTS="/opt/sdd/agents"
BUILTIN_ROOT_COMMANDS="/opt/commands"
RUNTIME_HOME="/opt/claude-runtime-home"

# ── settings_merge_host_overrides ────────────────────────────
# Part 1: merge /tmp/host-settings.json into $HOME/.claude/settings.json
# Part 2: detect if built-in agents/commands need merging into a runtime home
#
# Global state set after call:
#   EFFECTIVE_HOME — HOME to use when launching claude
settings_merge_host_overrides() {
  # ── Part 1: merge host settings with container hooks ─────────
  if [ -f "$HOST_SETTINGS" ] && [ -f "$CONTAINER_SETTINGS" ]; then
    echo "⚙️  Merging host settings with container hooks..."
    MERGED=$(jq -s '
      .[0] * .[1]
      | .hooks = (.[0].hooks // {}) * (.[1].hooks // {})
      | .statusLine = (.[1].statusLine // .[0].statusLine // null)
      | if .statusLine == null then del(.statusLine) else . end
    ' "$HOST_SETTINGS" "$CONTAINER_SETTINGS" 2>/dev/null) || true
    if [ -n "$MERGED" ]; then
      echo "$MERGED" > "$CONTAINER_SETTINGS"
      echo "  ✓ Settings merged (host preferences + container hooks)"
    fi
  elif [ -f "$HOST_SETTINGS" ]; then
    cp "$HOST_SETTINGS" "$CONTAINER_SETTINGS"
    echo "  ✓ Host settings applied"
  fi

  # ── Part 2: detect whether built-in files survive host mounts ─
  # If host mounted ~/.claude/agents or ~/.claude/commands (read-only),
  # they shadow the Dockerfile copies. Merge built-in files into a writable dir.
  local NEEDS_MERGE=false

  # Host-mounted ~/.claude/agents or ~/.claude/commands should always be merged
  # into a writable runtime home so repo-owned Walter files can override stale
  # duplicates from the host while preserving host-only custom files.
  if [ -n "${WALTER_HOST_AGENTS_MOUNTED:-}" ] || [ -n "${WALTER_HOST_COMMANDS_MOUNTED:-}" ]; then
    NEEDS_MERGE=true
  fi

  # Check if built-in agents need merging
  if [ "$NEEDS_MERGE" != true ] && [ -d "$AGENTS_DIR" ] && [ -d "$BUILTIN_AGENTS_DIR" ]; then
    for f in "$BUILTIN_AGENTS_DIR"/*.md; do
      [ -f "$f" ] || continue
      fname=$(basename "$f")
      if [ ! -f "$AGENTS_DIR/$fname" ]; then
        NEEDS_MERGE=true
        break
      fi
    done
  fi

  # Check if built-in SDD agents need merging
  if [ "$NEEDS_MERGE" != true ] && [ -d "$AGENTS_DIR" ] && [ -d "$BUILTIN_SDD_AGENTS" ]; then
    for f in "$BUILTIN_SDD_AGENTS"/*.md; do
      [ -f "$f" ] || continue
      fname=$(basename "$f")
      if [ ! -f "$AGENTS_DIR/$fname" ]; then
        NEEDS_MERGE=true
        break
      fi
    done
  fi

  # Check if built-in SDD commands need merging
  if [ "$NEEDS_MERGE" != true ] && [ -d "$COMMANDS_DIR" ] && [ -d "$BUILTIN_COMMANDS_DIR" ]; then
    for f in "$BUILTIN_COMMANDS_DIR"/*.md; do
      [ -f "$f" ] || continue
      fname=$(basename "$f")
      if [ ! -f "$COMMANDS_DIR/sdd/$fname" ]; then
        NEEDS_MERGE=true
        break
      fi
    done
  fi

  # Check if built-in root commands (peer-review etc.) need merging
  if [ "$NEEDS_MERGE" != true ] && [ -d "$COMMANDS_DIR" ] && [ -d "$BUILTIN_ROOT_COMMANDS" ]; then
    for f in "$BUILTIN_ROOT_COMMANDS"/*.md; do
      [ -f "$f" ] || continue
      fname=$(basename "$f")
      if [ ! -f "$COMMANDS_DIR/$fname" ]; then
        NEEDS_MERGE=true
        break
      fi
    done
  fi

  # ── Compute effective HOME ─────────────────────────────────
  EFFECTIVE_HOME="$HOME"

  if [ "$NEEDS_MERGE" = true ]; then
    mkdir -p "$RUNTIME_HOME/.claude"

    # Copy HOME selectively — skip .claude/projects (mounted volume, can be huge)
    # Copy top-level files
    for f in "$HOME"/.* "$HOME"/*; do
      fname=$(basename "$f")
      [ "$fname" = "." ] || [ "$fname" = ".." ] && continue
      [ "$fname" = ".claude" ] && continue
      cp -a "$f" "$RUNTIME_HOME/" 2>/dev/null || true
    done
    # Copy .claude/ contents except projects/
    for f in "$HOME/.claude"/*; do
      fname=$(basename "$f")
      [ "$fname" = "projects" ] && continue
      cp -a "$f" "$RUNTIME_HOME/.claude/" 2>/dev/null || true
    done

    # Merge built-in agents
    mkdir -p "$RUNTIME_HOME/.claude/agents"
    for f in "$BUILTIN_AGENTS_DIR"/*.md; do
      [ -f "$f" ] && cp "$f" "$RUNTIME_HOME/.claude/agents/"
    done
    for f in "$BUILTIN_SDD_AGENTS"/*.md; do
      [ -f "$f" ] && cp "$f" "$RUNTIME_HOME/.claude/agents/"
    done

    # Merge built-in commands
    mkdir -p "$RUNTIME_HOME/.claude/commands/sdd"
    for f in "$BUILTIN_COMMANDS_DIR"/*.md; do
      [ -f "$f" ] && cp "$f" "$RUNTIME_HOME/.claude/commands/sdd/"
    done
    # Merge root commands (peer-review etc.)
    for f in "$BUILTIN_ROOT_COMMANDS"/*.md; do
      [ -f "$f" ] && cp "$f" "$RUNTIME_HOME/.claude/commands/"
    done

    # Symlink projects back to the mounted volume so session data persists
    ln -s "$HOME/.claude/projects" "$RUNTIME_HOME/.claude/projects"
    chown -R -h node:node "$RUNTIME_HOME"
    echo "  ✓ Built-in agents + commands merged into runtime home"
    EFFECTIVE_HOME="$RUNTIME_HOME"
  fi
}
