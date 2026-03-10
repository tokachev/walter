#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  plan-executor.sh — Sequential plan execution for Walter
#
#  Reads a markdown plan file with ### Task N: headers,
#  executes each task in a fresh `claude -p` session,
#  handles [WAIT] items and retries.
# ══════════════════════════════════════════════════════════════

set -euo pipefail

# ── Config ──────────────────────────────────────────────────
MAX_ITERATIONS="${WALTER_MAX_ITERATIONS:-600}"
RETRY_COUNT="${WALTER_RETRY_COUNT:-2}"
CLAUDE_ARGS_STR="${WALTER_CLAUDE_ARGS_STR:-}"
SIGNAL_FILE="/tmp/.walter-signal"
WAVE_FILTER="${WALTER_WAVE:-}"
PLAN_DIR="${WALTER_PLAN_DIR:-}"

# Resolve plan file(s)
if [ -n "$PLAN_DIR" ]; then
  # --plan-dir mode: execute all phase-*-PLAN.md files in sequence
  if [ ! -d "$PLAN_DIR" ]; then
    echo "ERROR: Plan directory not found: $PLAN_DIR" >&2
    exit 1
  fi
  PLAN_FILES=()
  for f in "$PLAN_DIR"/phase-*-PLAN.md "$PLAN_DIR"/phase-*-*-PLAN.md "$PLAN_DIR"/quick-PLAN.md; do
    [ -f "$f" ] && PLAN_FILES+=("$f")
  done
  # Deduplicate and sort
  PLAN_FILES=($(printf '%s\n' "${PLAN_FILES[@]}" | sort -u))
  if [ ${#PLAN_FILES[@]} -eq 0 ]; then
    echo "ERROR: No plan files found in $PLAN_DIR" >&2
    exit 1
  fi
  echo "Plan directory mode: found ${#PLAN_FILES[@]} plan file(s)"
  PLAN_FILE="${PLAN_FILES[0]}"
else
  PLAN_FILE="${WALTER_PLAN_FILE:?WALTER_PLAN_FILE is required}"
  PLAN_FILES=("$PLAN_FILE")
fi

# Parse CLAUDE_ARGS_STR back into array
CLAUDE_ARGS=()
if [ -n "$CLAUDE_ARGS_STR" ]; then
  read -ra CLAUDE_ARGS <<< "$CLAUDE_ARGS_STR"
fi

# ── Helpers ─────────────────────────────────────────────────

log() { echo "▸ $*"; }
log_ok() { echo "  ✓ $*"; }
log_err() { echo "  ✗ $*" >&2; }
log_warn() { echo "  ⚠ $*"; }

# extract_plan_context — returns everything before the first ### Task header (capped at 200 lines)
extract_plan_context() {
  local plan="$1"
  local result=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^###[[:space:]]+Task[[:space:]]+[0-9]+ ]]; then
      break
    fi
    result+="$line"$'\n'
  done < "$plan"
  # If no Task header was found, return empty to avoid injecting the whole file
  if ! grep -qE '^###[[:space:]]+Task[[:space:]]+[0-9]+' "$plan" 2>/dev/null; then
    echo ""
    return 0
  fi
  printf '%s' "$result" | head -200
}

# find_next_task — returns the task number of the first task with unchecked items.
# Scans for ### Task N: headers and checks if there are - [ ] or - [WAIT] items.
# Optional second arg: wave filter (comma-separated task numbers). If set, only
# tasks in the wave are considered.
# Returns empty string if all tasks are done (or none in the wave are pending).
find_next_task() {
  local plan="$1"
  local wave="${2:-}"
  local current_task=""
  local has_unchecked=false

  # Inner helper: check if a task number is in the given wave string.
  # Returns 0 (true) if wave is empty or task is listed; 1 otherwise.
  _task_in_wave() {
    local tnum="$1"
    local wv="$2"
    [ -z "$wv" ] && return 0
    local IFS=','
    local wt
    for wt in $wv; do
      [ "$wt" = "$tnum" ] && return 0
    done
    return 1
  }

  while IFS= read -r line; do
    # ## headers (Done Criteria, Table sections, etc.) end the current task scope
    if [[ "$line" =~ ^##[[:space:]] && ! "$line" =~ ^### ]]; then
      if [ "$has_unchecked" = true ] && [ -n "$current_task" ]; then
        if _task_in_wave "$current_task" "$wave"; then
          echo "$current_task"
          return 0
        fi
        # Not in wave — reset and keep scanning
        has_unchecked=false
      fi
      current_task=""
      has_unchecked=false
      continue
    fi
    # Match ### Task N: header (with optional text after)
    if [[ "$line" =~ ^###[[:space:]]+Task[[:space:]]+([0-9]+) ]]; then
      # If previous task had unchecked items, check wave before returning
      if [ "$has_unchecked" = true ] && [ -n "$current_task" ]; then
        if _task_in_wave "$current_task" "$wave"; then
          echo "$current_task"
          return 0
        fi
        # Not in wave — reset and keep scanning
        has_unchecked=false
      fi
      current_task="${BASH_REMATCH[1]}"
      has_unchecked=false
    fi
    # Check for unchecked items
    if [ -n "$current_task" ]; then
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]\[[[:space:]]\] ]] || \
         [[ "$line" =~ ^[[:space:]]*-[[:space:]]\[WAIT\] ]]; then
        has_unchecked=true
      fi
    fi
  done < "$plan"

  # Check last task
  if [ "$has_unchecked" = true ] && [ -n "$current_task" ]; then
    if _task_in_wave "$current_task" "$wave"; then
      echo "$current_task"
      return 0
    fi
  fi

  echo ""
}

# extract_task_title — returns the title from a ### Task N: <title> header
extract_task_title() {
  local plan="$1"
  local task_num="$2"

  while IFS= read -r line; do
    if [[ "$line" =~ ^###[[:space:]]+Task[[:space:]]+${task_num}:[[:space:]]*(.*) ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    fi
  done < "$plan"

  echo "Task $task_num"
}

# extract_task_section — returns the full text of a task section (from header to next header)
extract_task_section() {
  local plan="$1"
  local task_num="$2"
  local in_section=false

  while IFS= read -r line; do
    if [[ "$line" =~ ^###[[:space:]]+Task[[:space:]]+${task_num}[[:space:]:]  ]]; then
      in_section=true
      echo "$line"
      continue
    fi
    if [ "$in_section" = true ]; then
      # Stop at next task header or ## header
      if [[ "$line" =~ ^###[[:space:]]+Task[[:space:]]+[0-9]+ ]] || \
         [[ "$line" =~ ^##[[:space:]] && ! "$line" =~ ^### ]]; then
        break
      fi
      echo "$line"
    fi
  done < "$plan"
}

# extract_validation_commands — pulls ## Validation Commands section
extract_validation_commands() {
  local plan="$1"
  local in_section=false

  while IFS= read -r line; do
    if [[ "$line" =~ ^##[[:space:]]+Validation[[:space:]]+Commands ]]; then
      in_section=true
      continue
    fi
    if [ "$in_section" = true ]; then
      # Stop at next ## header
      if [[ "$line" =~ ^##[[:space:]] ]]; then
        break
      fi
      echo "$line"
    fi
  done < "$plan"
}

# count_incomplete_tasks — counts remaining - [ ] or - [WAIT] lines in the entire plan
count_incomplete_tasks() {
  local plan="$1"
  grep -cE '^\s*-\s\[\s\]|^\s*-\s\[WAIT\]' "$plan" 2>/dev/null || echo "0"
}

# get_first_unchecked — returns first - [ ] or - [WAIT] line in a task section
get_first_unchecked() {
  local plan="$1"
  local task_num="$2"
  local section
  section=$(extract_task_section "$plan" "$task_num")
  echo "$section" | grep -m1 -E '^\s*-\s\[\s\]|^\s*-\s\[WAIT\]' || true
}


# ── Wave filter helper ──────────────────────────────────────

# filter_tasks_by_wave — if WAVE_FILTER is set, only process tasks in that wave.
# Wave = comma-separated task numbers. E.g., WALTER_WAVE="1,2,3"
is_task_in_wave() {
  local task_num="$1"
  if [ -z "$WAVE_FILTER" ]; then
    return 0  # no filter = all tasks
  fi
  IFS=',' read -ra WAVE_TASKS <<< "$WAVE_FILTER"
  for wt in "${WAVE_TASKS[@]}"; do
    [ "$wt" = "$task_num" ] && return 0
  done
  return 1
}

# ── Execute single plan file ──────────────────────────────────

execute_plan() {
  local plan_file="$1"

echo ""
echo "══════════════════════════════════════════════════════"
echo "  walter plan-executor"
echo ""
echo "  Plan:           $plan_file"
echo "  Max iterations: $MAX_ITERATIONS"
echo "  Retry count:    $RETRY_COUNT"
[ -n "$WAVE_FILTER" ] && echo "  Wave filter:    tasks $WAVE_FILTER"
echo "══════════════════════════════════════════════════════"
echo ""

# ── Validate plan file ──────────────────────────────────────

if [ ! -f "$plan_file" ]; then
  log_err "Plan file not found: $plan_file"
  return 1
fi


# ── Main loop ───────────────────────────────────────────────

touch /tmp/.walter-session-start

for ((iteration=1; iteration<=MAX_ITERATIONS; iteration++)); do
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Iteration $iteration/$MAX_ITERATIONS"

  # Find next task with unchecked items (respects WAVE_FILTER if set)
  task_num=$(find_next_task "$plan_file" "$WAVE_FILTER")
  if [ -z "$task_num" ]; then
    echo ""
    log_ok "All tasks complete in $plan_file!"
    echo ""
    return 0
  fi

  task_title=$(extract_task_title "$plan_file" "$task_num")
  log "Task $task_num: $task_title"

  # Check if first unchecked item is [WAIT]
  first_unchecked=$(get_first_unchecked "$plan_file" "$task_num")

  if [[ "$first_unchecked" =~ \[WAIT\] ]]; then
    echo ""
    echo "  ⏸  WAIT step encountered:"
    echo "  $first_unchecked"
    echo ""

    if [ -t 0 ]; then
      read -rp "  Press ENTER to mark as done and continue..." _
    else
      log_warn "Non-interactive mode — cannot wait for user input"
      log_err "Aborting: [WAIT] step requires interactive terminal"
      return 1
    fi

    # Mark [WAIT] → [x] in plan file
    wait_pattern=$(echo "$first_unchecked" | sed 's/[][\/.^$*]/\\&/g' | sed 's/\[WAIT\]/\\[WAIT\\]/')
    wait_replacement=$(echo "$first_unchecked" | sed 's/\[WAIT\]/[x]/')
    wait_replacement_escaped=$(echo "$wait_replacement" | sed 's/[&/\]/\\&/g')
    sed -i "s/${wait_pattern}/${wait_replacement_escaped}/" "$plan_file"
    log_ok "Marked WAIT step as done"
    continue
  fi

  # Build task section, validation commands, and plan context
  task_section=$(extract_task_section "$plan_file" "$task_num")
  validation_cmds=$(extract_validation_commands "$plan_file")
  plan_context=$(extract_plan_context "$plan_file")

  # Build prompt
  prompt="You are executing a plan inside a walter container.
"
  if [ -n "$plan_context" ]; then
    prompt+="
PLAN CONTEXT (read carefully, applies to all tasks):
${plan_context}
"
  fi
  prompt+="Read the plan file at ${plan_file}.
You are executing Task ${task_num}: ${task_title}.
ONLY work on this task. Do NOT continue to the next task.

Here is the task section for reference:
${task_section}

Instructions:
1. ANNOUNCE: Give a brief overview of what you will do (max 200 words).
2. IMPLEMENT: Complete all unchecked [ ] items in Task ${task_num}. Skip any [WAIT] items.
3. VALIDATE: Run the following validation commands from the plan and fix any failures:
${validation_cmds}
4. COMPLETE: Mark each completed [ ] item as [x] in the plan file (${plan_file}). Do NOT commit.
   Then output EXACTLY ONE of the following — nothing else:
   - If ALL [ ] items in the ENTIRE plan are now [x] → output: <<<WALTER:ALL_TASKS_DONE>>>
   - If more tasks remain (even if this task was already done) → end your response with NO signal at all
   - If you hit an actual error that prevented the work → output: <<<WALTER:TASK_FAILED>>>
   NOTE: a task that was already complete is NOT a failure. Do NOT output TASK_FAILED in that case.

IMPORTANT: You MUST output one of the signal strings above before finishing."

  # Run claude with retry logic
  retries=0
  task_success=false

  while [ "$retries" -le "$RETRY_COUNT" ]; do
    if [ "$retries" -gt 0 ]; then
      log_warn "Retry $retries/$RETRY_COUNT for Task $task_num"
    fi

    # Clear signal file
    rm -f "$SIGNAL_FILE"
    echo "UNKNOWN" > "$SIGNAL_FILE"

    log "Running claude -p for Task $task_num..."
    echo ""

    # Run claude and scan output for signals using process substitution
    exit_code=0
    while IFS= read -r line; do
      echo "$line"
      if [[ "$line" == *'<<<WALTER:ALL_TASKS_DONE>>>'* ]]; then
        echo "ALL_TASKS_DONE" > "$SIGNAL_FILE"
      elif [[ "$line" == *'<<<WALTER:TASK_FAILED>>>'* ]]; then
        echo "TASK_FAILED" > "$SIGNAL_FILE"
      fi
    done < <(claude "${CLAUDE_ARGS[@]}" -p "$prompt" --max-turns 30 --verbose 2>&1) || exit_code=$?

    echo ""

    # Read signal
    signal=$(cat "$SIGNAL_FILE" 2>/dev/null || echo "UNKNOWN")

    if [ "$exit_code" -ne 0 ] || [ "$signal" = "TASK_FAILED" ]; then
      retries=$((retries + 1))
      if [ "$retries" -gt "$RETRY_COUNT" ]; then
        log_err "Task $task_num FAILED after $RETRY_COUNT retries"
        return 1
      fi
      log_warn "Task $task_num failed (exit=$exit_code, signal=$signal)"
      sleep 2
      continue
    fi

    if [ "$signal" = "ALL_TASKS_DONE" ]; then
      echo ""
      log_ok "All tasks complete!"
      echo ""
      return 0
    fi

    # Task completed normally (more tasks remain)
    task_success=true
    break
  done

  if [ "$task_success" = true ]; then
    remaining=$(count_incomplete_tasks "$plan_file")
    log_ok "Task $task_num done. Remaining unchecked items: $remaining"
  fi

  sleep 2
done

log_err "Reached max iterations ($MAX_ITERATIONS) without completing all tasks"
return 1
}

# ── Multi-plan orchestrator ─────────────────────────────────

plan_idx=0
total_plans=${#PLAN_FILES[@]}

for pf in "${PLAN_FILES[@]}"; do
  plan_idx=$((plan_idx + 1))
  if [ "$total_plans" -gt 1 ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "  Plan $plan_idx/$total_plans: $(basename "$pf")"
    echo "╚══════════════════════════════════════════════════════╝"
  fi
  execute_plan "$pf"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log_err "Plan execution failed: $pf"
    exit 1
  fi
done

echo ""
log_ok "All plan files executed successfully!"

if [ "${WALTER_REVIEW:-}" = "true" ]; then
  log "Handing off to review-executor..."
  exec /opt/review/review-executor.sh
fi

exit 0
