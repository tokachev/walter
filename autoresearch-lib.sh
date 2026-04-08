#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  autoresearch-lib.sh — Helper library for autoresearch loop
#
#  Source this file; do not execute directly.
#  Provides: logging, progress events, eval execution,
#            results tracking, and git experiment management.
# ══════════════════════════════════════════════════════════════

set -euo pipefail

# ── Config ──────────────────────────────────────────────────

PROGRESS_FILE="${PROGRESS_FILE:-/var/log/walter/progress.jsonl}"
RESULTS_FILE="${RESULTS_FILE:-results.tsv}"

# ── Logging ─────────────────────────────────────────────────

log()      { echo "▸ $*"; }
log_ok()   { echo "  ✓ $*"; }
log_err()  { echo "  ✗ $*" >&2; }
log_warn() { echo "  ⚠ $*"; }

# log_progress — write a structured JSON line to $PROGRESS_FILE
# Usage: log_progress '"event":"session_start","tag":"my-tag"'
log_progress() {
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "{\"ts\":\"$ts\",$1}" >> "$PROGRESS_FILE" 2>/dev/null || true
}

# log_result — append one TSV row to $RESULTS_FILE
# Usage: log_result <iteration> <metric_value> <description> <status>
# status: keep | discard | baseline
log_result() {
  local iteration="$1"
  local metric_value="$2"
  local description="$3"
  local status="$4"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$iteration" "$metric_value" "$description" "$status" "$ts" \
    >> "$RESULTS_FILE"
}

# run_eval — execute eval command, capture last numeric line of stdout as metric
# Usage: metric=$(run_eval "bash /workspace/sandbox/eval.sh")
# Exits 0 on success; exits non-zero if no numeric line found.
run_eval() {
  local eval_cmd="$1"
  local output
  output=$(eval "$eval_cmd" 2>&1)
  # Extract last line that is purely numeric (integer or decimal, optional sign)
  local metric
  metric=$(echo "$output" | grep -E '^-?[0-9]+(\.[0-9]+)?$' | tail -1)
  if [ -z "$metric" ]; then
    log_err "run_eval: no numeric line found in eval output"
    log_err "eval output was:"
    echo "$output" >&2
    return 1
  fi
  echo "$metric"
}

# ── Git Experiment Management ────────────────────────────────

# git_experiment_start — create or checkout branch autoresearch/<tag>
# Usage: git_experiment_start "my-tag"
git_experiment_start() {
  local tag="$1"
  local branch="autoresearch/${tag}"

  if git rev-parse --verify "$branch" >/dev/null 2>&1; then
    log "Resuming existing branch: $branch"
    git checkout "$branch"
  else
    log "Creating experiment branch: $branch"
    git checkout -b "$branch"
  fi
}

# git_experiment_keep — commit current changes as an improvement
# Usage: git_experiment_keep <iteration> <metric>
git_experiment_keep() {
  local iteration="$1"
  local metric="$2"
  git add -A
  if git diff --cached --quiet 2>/dev/null; then
    log_warn "No changes to commit in iteration ${iteration}"
    return 0
  fi
  git commit -m "autoresearch: iteration ${iteration} — metric=${metric} (improved)"
  log_ok "Committed iteration ${iteration} (metric=${metric})"
}

# git_experiment_discard — stash current changes as a regression
# Usage: git_experiment_discard <iteration> <metric>
git_experiment_discard() {
  local iteration="$1"
  local metric="$2"
  if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null; then
    log_warn "No changes to discard in iteration ${iteration}"
    return 0
  fi
  git stash push -m "autoresearch: iteration ${iteration} — metric=${metric} (regression)"
  git checkout .
  log_warn "Discarded iteration ${iteration} (metric=${metric}, regression stashed)"
}
