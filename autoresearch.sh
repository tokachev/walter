#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  autoresearch.sh — Autonomous research loop for Walter
#
#  Infinite (or bounded) cycle: each iteration launches a fresh
#  `claude -p` session that modifies TARGET_FILE, runs EVAL_COMMAND,
#  and emits IMPROVED / NO_IMPROVEMENT. Improvements are committed;
#  regressions are stashed and discarded.
#
#  Usage:
#    autoresearch.sh --target-file FILE --eval-command CMD --tag TAG \
#                    [--max-iterations N] [--results-file FILE]
# ══════════════════════════════════════════════════════════════

set -euo pipefail

# ── Locate script directory ─────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Source library ──────────────────────────────────────────
# shellcheck source=autoresearch-lib.sh
source "$SCRIPT_DIR/autoresearch-lib.sh"

# ── Defaults ────────────────────────────────────────────────
TARGET_FILE=""
EVAL_COMMAND=""
TAG=""
MAX_ITERATIONS=0
RESULTS_FILE="results.tsv"
SHUTDOWN=false

# ── Signal handling ─────────────────────────────────────────
cleanup() {
  SHUTDOWN=true
}
trap cleanup SIGINT SIGTERM

# ── Arg parsing ─────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-file)
      TARGET_FILE="$2"; shift 2 ;;
    --eval-command)
      EVAL_COMMAND="$2"; shift 2 ;;
    --tag)
      TAG="$2"; shift 2 ;;
    --max-iterations)
      MAX_ITERATIONS="$2"; shift 2 ;;
    --results-file)
      RESULTS_FILE="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1 ;;
  esac
done

# ── Validate required args ──────────────────────────────────
if [ -z "$TARGET_FILE" ] || [ -z "$EVAL_COMMAND" ] || [ -z "$TAG" ]; then
  echo "Usage: autoresearch.sh --target-file FILE --eval-command CMD --tag TAG" >&2
  echo "         [--max-iterations N] [--results-file FILE]" >&2
  exit 1
fi

# ── Parse CLAUDE_ARGS ───────────────────────────────────────
CLAUDE_ARGS=()
if [ -n "${WALTER_CLAUDE_ARGS_STR:-}" ]; then
  read -ra CLAUDE_ARGS <<< "${WALTER_CLAUDE_ARGS_STR:-}"
fi

# ── Results file: write header only if file doesn't exist ───
if [ ! -f "$RESULTS_FILE" ]; then
  printf 'iteration\tmetric\tdescription\tstatus\ttimestamp\n' > "$RESULTS_FILE"
fi

# ── Baseline run ────────────────────────────────────────────
log "Running baseline eval..."
BASELINE_METRIC=$(run_eval "$EVAL_COMMAND")
log_ok "Baseline metric: $BASELINE_METRIC"
log_result 0 "$BASELINE_METRIC" "baseline" "baseline"

# ── Setup experiment branch ─────────────────────────────────
git_experiment_start "$TAG"

# ── Banner ──────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo "  walter autoresearch"
echo ""
echo "  Target:         $TARGET_FILE"
echo "  Eval:           $EVAL_COMMAND"
echo "  Tag:            $TAG"
echo "  Max iterations: $MAX_ITERATIONS (0=infinite)"
echo "  Baseline:       $BASELINE_METRIC"
echo "══════════════════════════════════════════════════════"
echo ""

# ── Main iteration loop ─────────────────────────────────────
CURRENT_METRIC="$BASELINE_METRIC"

for ((iteration=1; ; iteration++)); do

  # Shutdown check
  if [ "$SHUTDOWN" = true ]; then
    log_warn "Shutdown signal received — exiting loop"
    break
  fi

  # Max iterations check
  if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$iteration" -gt "$MAX_ITERATIONS" ]; then
    log "Max iterations ($MAX_ITERATIONS) reached"
    break
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Iteration $iteration"

  # Build prompt from template
  prompt=$(sed \
    -e "s|{{TARGET_FILE}}|$TARGET_FILE|g" \
    -e "s|{{EVAL_COMMAND}}|$EVAL_COMMAND|g" \
    -e "s|{{RESULTS_TSV}}|$RESULTS_FILE|g" \
    -e "s|{{BASELINE_METRIC}}|$BASELINE_METRIC|g" \
    "$SCRIPT_DIR/autoresearch-program.md")

  # Run claude and scan output for signals
  signal_detected=""
  detected_metric="$CURRENT_METRIC"

  while IFS= read -r line; do
    echo "$line"
    if [[ "$line" == *'<<<AUTORESEARCH:IMPROVED>>>'* ]]; then
      signal_detected="IMPROVED"
    elif [[ "$line" == *'<<<AUTORESEARCH:NO_IMPROVEMENT>>>'* ]]; then
      signal_detected="NO_IMPROVEMENT"
    fi
  done < <(claude "${CLAUDE_ARGS[@]}" -p "$prompt" --max-turns 30 --verbose 2>&1) || true

  echo ""

  # Evaluate current state of the target file
  new_metric=$(run_eval "$EVAL_COMMAND" 2>/dev/null || echo "$CURRENT_METRIC")

  # Apply keep/discard based on signal (or safe default)
  case "$signal_detected" in
    IMPROVED)
      log_ok "Iteration $iteration: improvement detected (metric=$new_metric)"
      git_experiment_keep "$iteration" "$new_metric"
      log_result "$iteration" "$new_metric" "iteration-${iteration}" "keep"
      CURRENT_METRIC="$new_metric"
      ;;
    *)
      # NO_IMPROVEMENT or no signal — discard (safe default)
      if [ "$signal_detected" = "NO_IMPROVEMENT" ]; then
        log_warn "Iteration $iteration: no improvement (metric=$new_metric)"
      else
        log_warn "Iteration $iteration: no signal detected — discarding as safe default"
      fi
      git_experiment_discard "$iteration" "$new_metric"
      log_result "$iteration" "$new_metric" "iteration-${iteration}" "discard"
      ;;
  esac

  sleep 2
done

# ── Session summary ─────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo "  autoresearch session complete"
echo ""

total_iterations=$((iteration - 1))

# Count kept/discarded from results file (skip header row)
kept_count=$(tail -n +2 "$RESULTS_FILE" | grep -c $'\tkeep\t' 2>/dev/null || echo "0")
discarded_count=$(tail -n +2 "$RESULTS_FILE" | grep -c $'\tdiscard\t' 2>/dev/null || echo "0")

# Best metric: numeric sort on column 2 (ascending = lowest is best; use tail for highest)
best_metric=$(tail -n +2 "$RESULTS_FILE" | awk -F'\t' '{print $2}' | sort -n | tail -1 2>/dev/null || echo "$BASELINE_METRIC")

echo "  Total iterations: $total_iterations"
echo "  Kept:             $kept_count"
echo "  Discarded:        $discarded_count"
echo "  Best metric:      $best_metric"
echo "  Baseline:         $BASELINE_METRIC"
echo "══════════════════════════════════════════════════════"
echo ""

exit 0
