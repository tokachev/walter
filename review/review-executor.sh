#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  review-executor.sh — Code review orchestrator for Walter
#
#  Runs 3 review phases sequentially:
#   Phase 1 — First Review: 5 agents + evaluation
#   Phase 2 — External Review: Codex dispatch + evaluation
#   Phase 3 — Final Review: 2 agents + evaluation
#
#  Env vars:
#   WALTER_PLAN_FILE  — path to the plan file that was executed
#   WALTER_PLAN_GOAL  — short goal string (extracted from plan if unset)
#   WALTER_REVIEW_SKIP — comma-separated phases to skip: first,external,final
# ══════════════════════════════════════════════════════════════

set -euo pipefail

# ── Config ──────────────────────────────────────────────────

FINDINGS_DIR="/tmp/walter-review"
RENDERED_DIR="/tmp/walter-review/rendered"
REVIEW_SKIP="${WALTER_REVIEW_SKIP:-}"
REVIEW_MODEL="claude-opus-4-20250514"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
AGENTS_DIR="${SCRIPT_DIR}/agents"
PROMPTS_DIR="${SCRIPT_DIR}/prompts"

# ── Logging helpers ──────────────────────────────────────────

log()      { echo "▸ $*"; }
log_ok()   { echo "  ✓ $*"; }
log_err()  { echo "  ✗ $*" >&2; }
log_warn() { echo "  ⚠ $*"; }

# ── should_skip ──────────────────────────────────────────────
# Returns 0 (true) if the given phase name is in $REVIEW_SKIP
should_skip() {
  local phase="$1"
  if [ -z "$REVIEW_SKIP" ]; then
    return 1
  fi
  local IFS=','
  for s in $REVIEW_SKIP; do
    if [ "$s" = "$phase" ]; then
      return 0
    fi
  done
  return 1
}

# ── render_prompt ────────────────────────────────────────────
# Usage: render_prompt <template_path>
# Outputs rendered content to $RENDERED_DIR/<basename>
# Replaces: {{CHANGED_FILES}}, {{PLAN_FILE}}, {{GOAL}}, {{FINDINGS_DIR}}
render_prompt() {
  local template="$1"
  local basename
  basename="$(basename "$template")"
  local output="${RENDERED_DIR}/${basename}"

  if [ ! -f "$template" ]; then
    log_err "Template not found: $template"
    return 1
  fi

  # Two-pass substitution:
  # 1. awk reads changed-files.txt as first file (NR==FNR), builds multiline var
  # 2. Processes template, replaces all placeholders
  # This avoids awk -v with newlines (POSIX violation)
  awk -v plan_file="$PLAN_FILE" \
      -v goal="$GOAL" \
      -v findings_dir="$FINDINGS_DIR" '
  NR==FNR { changed_files = (NR==1 ? $0 : changed_files "\n" $0); next }
  {
    gsub(/\{\{CHANGED_FILES\}\}/, changed_files)
    gsub(/\{\{PLAN_FILE\}\}/, plan_file)
    gsub(/\{\{GOAL\}\}/, goal)
    gsub(/\{\{FINDINGS_DIR\}\}/, findings_dir)
    print
  }
  ' "${FINDINGS_DIR}/changed-files.txt" "$template" > "$output"

  echo "$output"
}

# ── detect_changed_files ─────────────────────────────────────
detect_changed_files() {
  log "Detecting changed files..."

  local out="${FINDINGS_DIR}/changed-files.txt"

  # Explicit file list takes priority over detection
  if [ -n "${WALTER_REVIEW_FILES:-}" ]; then
    echo "$WALTER_REVIEW_FILES" | tr ',' '\n' > "$out"
    log "  Using explicit file list (WALTER_REVIEW_FILES)"
  elif [ -f "/tmp/.walter-session-start" ]; then
    find . -newer "/tmp/.walter-session-start" -type f \
      -not -path './.git/*' \
      -not -path './node_modules/*' \
      -not -path './__pycache__/*' \
      -not -path './.planning/*' \
      -not -path '/tmp/*' \
      > "$out" 2>/dev/null || true
    log "  Using session-start marker (find -newer)"
  else
    log_warn "No session-start marker found — falling back to git diff main"
    git diff --name-only main > "$out" 2>/dev/null || true
  fi

  local count
  count=$(wc -l < "$out" | tr -d ' ')

  if [ "$count" -eq 0 ]; then
    log_warn "No changed files detected — nothing to review"
    exit 0
  fi

  log_ok "Found $count changed file(s)"
}

# ── run_agent ────────────────────────────────────────────────
# Usage: run_agent <agent_name>
# Renders review/agents/<name>.md, runs claude -p, streams output
# On failure: logs warning but continues (does not abort)
run_agent() {
  local agent_name="$1"
  local template="${AGENTS_DIR}/${agent_name}.md"

  log "Running agent: ${agent_name}"

  local rendered
  rendered="$(render_prompt "$template")"

  local exit_code=0
  claude -p "$(cat "$rendered")" \
    --model "$REVIEW_MODEL" \
    --max-turns 20 \
    --verbose 2>&1 || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    log_warn "Agent '${agent_name}' exited with code ${exit_code} — continuing"
    return 0
  fi

  local findings="${FINDINGS_DIR}/${agent_name}.md"
  if [ ! -f "$findings" ]; then
    log_warn "Agent '${agent_name}' did not produce findings file: ${findings}"
  else
    log_ok "Agent '${agent_name}' complete — findings at ${findings}"
  fi
}

# ── run_evaluation ───────────────────────────────────────────
# Usage: run_evaluation <prompt_name>
# Renders review/prompts/<name>.md, runs claude -p with --max-turns 30
run_evaluation() {
  local prompt_name="$1"
  local template="${PROMPTS_DIR}/${prompt_name}.md"

  log "Running evaluation: ${prompt_name}"

  local rendered
  rendered="$(render_prompt "$template")"

  local exit_code=0
  claude -p "$(cat "$rendered")" \
    --model "$REVIEW_MODEL" \
    --max-turns 30 \
    --verbose 2>&1 || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    log_warn "Evaluation '${prompt_name}' exited with code ${exit_code}"
  else
    log_ok "Evaluation '${prompt_name}' complete"
  fi

  return "$exit_code"
}

# ── Phase 1: First Review ────────────────────────────────────
phase_first_review() {
  if should_skip "first"; then
    log_warn "Skipping phase: first (WALTER_REVIEW_SKIP)"
    return 0
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Phase 1: First Review"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  run_agent "quality"
  run_agent "implementation"
  run_agent "testing"
  run_agent "simplification"
  run_agent "docs"

  run_evaluation "evaluate-first"

  log_ok "Phase 1 complete"
}

# ── Phase 2: External Review (Codex) ────────────────────────
phase_external_review() {
  if should_skip "external"; then
    log_warn "Skipping phase: external (WALTER_REVIEW_SKIP)"
    return 0
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Phase 2: External Review (Codex)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if ! command -v codex > /dev/null 2>&1; then
    log_warn "Codex not found, skipping external review"
    return 0
  fi

  run_evaluation "codex-review"

  log_ok "Phase 2 complete"
}

# ── Phase 3: Final Review ────────────────────────────────────
phase_final_review() {
  if should_skip "final"; then
    log_warn "Skipping phase: final (WALTER_REVIEW_SKIP)"
    return 0
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Phase 3: Final Review"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  run_agent "final-quality"
  run_agent "final-impl"

  run_evaluation "evaluate-final"

  log_ok "Phase 3 complete"
}

# ── Main ─────────────────────────────────────────────────────

# Parse env vars
PLAN_FILE="${WALTER_PLAN_FILE:-}"
GOAL="${WALTER_PLAN_GOAL:-}"

# Validate plan file
if [ -z "$PLAN_FILE" ]; then
  log_warn "WALTER_PLAN_FILE not set — plan context will be empty"
  PLAN_FILE="(none)"
elif [ ! -f "$PLAN_FILE" ]; then
  log_warn "Plan file not found: $PLAN_FILE"
fi

# Extract goal from plan file if not provided
if [ -z "$GOAL" ] && [ -f "$PLAN_FILE" ]; then
  GOAL="$(grep -m1 '^# ' "$PLAN_FILE" | sed 's/^# //')"
fi

if [ -z "$GOAL" ]; then
  GOAL="(no goal specified)"
fi

# Banner
echo ""
echo "══════════════════════════════════════════════════════"
echo "  walter review-executor"
echo ""
echo "  Plan:    ${PLAN_FILE}"
echo "  Goal:    ${GOAL}"
echo "  Skip:    ${REVIEW_SKIP:-none}"
echo "  Model:   ${REVIEW_MODEL}"
echo "══════════════════════════════════════════════════════"
echo ""

# Clean and recreate working dirs
rm -rf "$FINDINGS_DIR"
mkdir -p "$FINDINGS_DIR"
mkdir -p "$RENDERED_DIR"

# Detect changed files
detect_changed_files

# Run all three review phases
phase_first_review
phase_external_review
phase_final_review

# Final banner
echo ""
echo "══════════════════════════════════════════════════════"
log_ok "Review complete"
echo "  Findings: ${FINDINGS_DIR}"
echo "══════════════════════════════════════════════════════"
echo ""
