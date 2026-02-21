#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  Credential Guard — Native PreToolUse Hook for Claude Code
#
#  Called by Claude Code via native hooks (settings.json).
#  Matchers route by tool type; this script receives a mode
#  argument to know which content to extract.
#
#  Usage:
#    credential-guard.sh write   — scan file content before Write
#    credential-guard.sh edit    — scan replacement text before Edit
#    credential-guard.sh bash    — scan command + heredocs before Bash
#
#  Hook protocol (native):
#    stdin: JSON with tool_name, tool_input, session_id, etc.
#    exit 0 + no output: allow
#    exit 0 + JSON with hookSpecificOutput.permissionDecision="deny": block
#    exit 2 + stderr: block (stderr fed to Claude)
# ══════════════════════════════════════════════════════════════

set -uo pipefail

MODE="${1:-}"
SCANNER="/opt/hooks/scan-credentials.sh"

# ── Read hook input ──────────────────────────────────────────
HOOK_INPUT=$(cat)

# ── Helper: run scanner and handle result ────────────────────
run_scan() {
  local content="$1"
  local context="$2"

  if [ -z "$content" ]; then
    return 0
  fi

  SCAN_RESULT=$(echo "$content" | bash "$SCANNER" "-" "$context" 2>&1)
  SCAN_EXIT=$?

  if [ $SCAN_EXIT -eq 1 ]; then
    # Exit 1 = scanner found credentials → block
    CLEAN_RESULT=$(echo "$SCAN_RESULT" | sed 's/\x1b\[[0-9;]*m//g' | tr '\n' ' ')
    jq -n \
      --arg ctx "$context" \
      --arg details "$CLEAN_RESULT" \
      '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: ("Credential Guard: Secrets detected in " + $ctx + ". Use environment variables instead. " + $details)
        }
      }'
    exit 0
  elif [ $SCAN_EXIT -ne 0 ]; then
    # Any other non-zero = scanner itself failed → fail-open
    echo "⚠️ credential-guard: scanner error (exit $SCAN_EXIT), allowing operation" >&2
    return 0
  fi

  return 0
}

# ── Route by mode ────────────────────────────────────────────
case "$MODE" in
  write)
    # Extract file content from Write tool input
    CONTENT=$(echo "$HOOK_INPUT" | jq -r '
      .tool_input.content //
      .tool_input.file_text //
      ""
    ' 2>/dev/null || echo "")

    run_scan "$CONTENT" "file-write"
    ;;

  edit)
    # Extract replacement content from Edit tool input
    CONTENT=$(echo "$HOOK_INPUT" | jq -r '
      .tool_input.new_string //
      .tool_input.replacement //
      ""
    ' 2>/dev/null || echo "")

    run_scan "$CONTENT" "edit"
    ;;

  bash)
    # Extract command from Bash tool input
    COMMAND=$(echo "$HOOK_INPUT" | jq -r '
      .tool_input.command //
      .tool_input.cmd //
      ""
    ' 2>/dev/null || echo "")

    if [ -n "$COMMAND" ]; then
      # 1. Scan the command itself for inline secrets
      run_scan "$COMMAND" "bash-command"

      # 2. Extract content from file-writing constructs (heredocs, echo, printf)
      WRITE_CONTENT=$(echo "$COMMAND" | python3 -c "
import sys, re

cmd = sys.stdin.read()
chunks = []

# Heredocs: cat << 'EOF' > file ... EOF
for m in re.finditer(r\"<<-?\s*['\\\"]?(\w+)['\\\"]?.*?\n(.*?)\n\1\", cmd, re.DOTALL):
    chunks.append(m.group(2))

# echo '...' > file
for m in re.finditer(r'echo\s+[\"'\''](.*?)[\"'\'']\s*>>?\s*\S+', cmd, re.DOTALL):
    chunks.append(m.group(1))

# printf '...' > file
for m in re.finditer(r'printf\s+[\"'\''](.*?)[\"'\'']\s*>>?\s*\S+', cmd, re.DOTALL):
    chunks.append(m.group(1))

if chunks:
    print('\n'.join(chunks))
" 2>/dev/null || echo "")

      if [ -n "$WRITE_CONTENT" ]; then
        run_scan "$WRITE_CONTENT" "bash-file-write"
      fi
    fi
    ;;

  *)
    # Unknown mode — allow
    ;;
esac

# All clear
exit 0
