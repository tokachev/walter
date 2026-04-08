# Lessons Learned

Persistent store of mistakes, corrections, and rules learned across sessions.
Updated automatically after user corrections and verification failures.

## Format

Each lesson follows this structure:
```
### YYYY-MM-DD: {Short title}
- **Trigger**: What went wrong or what correction was made
- **Root cause**: Why it happened
- **Rule**: Preventive rule for future sessions
- **Applies to**: {component/phase/general}
```

## Rules Index

Quick-reference rules extracted from lessons below. Review these at session start.

<!-- Rules are appended here automatically -->

---

## Lesson Log

<!-- Lessons are appended here automatically -->

### 2026-04-07: Plan vocabulary lists must match REQUIREMENTS.md
- **Trigger**: Phase 1 plan Task 1 step 8 listed an ops vocabulary (`write|merge|forget|ingest|skip|delete|split|lint-run|auto-file`) that omitted `reingest`. Plan Task 3 then said "log_memory_op for each reingested file" without specifying the op name, so executor used `ingest`. R1.4 in REQUIREMENTS.md explicitly names `reingest` as a distinct first-class op. QA validator caught the mismatch — Phase 3 daemon would parse against the spec, not the partial list.
- **Root cause**: Two sources of truth — the plan's example vocabulary and REQUIREMENTS.md's R1.4 — diverged. Plan author copy-pasted a partial list without cross-referencing the spec.
- **Rule**: When a plan task lists a vocabulary/enum/set of allowed values, it MUST be cross-checked against REQUIREMENTS.md. If the spec defines the canonical set, the plan should reference it ("see R1.4 for full op vocabulary") instead of duplicating. If the plan must inline a list (for clarity), include EVERY item from the spec — never a subset.
- **Applies to**: walter-planner, plan-coordinator, all SDD plan generation

### 2026-04-07: Locale-dependent `sort -u` silently corrupts non-ASCII deduplication on macOS
- **Trigger**: Phase 2 `memory-graph.sh::_tokenize` built a stopwords pattern with `sort -u`. On macOS host with `LANG=en_US.UTF-8`, the BSD locale collation collapsed 56 Cyrillic stopwords down to 5 — meaning common Russian words (`для`, `что`, `не`, `как`, ...) leaked through as content tokens, lowering Jaccard scores and causing related-file detection to MISS Russian-language memory files entirely. No crash, no error, no test failure on ASCII inputs. Caught only by qa-validator's adversarial Cyrillic smoke test.
- **Root cause**: Default locale collation in macOS BSD `sort` is not deterministic across UTF-8 character sets — it treats most non-ASCII characters as collation-equivalent. The same code in a Linux container with `LANG=C` works correctly. Plan/code author used `sort -u` without considering locale impact on non-ASCII inputs.
- **Rule**: Any shell pipeline that does `sort`, `sort -u`, `comm`, or `uniq` on data that might contain non-ASCII (Cyrillic, CJK, accented Latin, emoji) MUST prefix the call with `LC_ALL=C` for byte-level comparison. This is especially critical for: stopwords lists, tokenizer output, dedup of frontmatter fields, file basename comparison. ASCII-only test data WILL pass and hide the bug — explicitly add a non-ASCII test case to validation suites for any tokenizer/dedup function.
- **Applies to**: all shell helpers handling user content, walter-planner (must include non-ASCII validation step), code-review-strict, qa-validator

### 2026-04-07: Wrappers around fail-open functions silence intentional stderr
- **Trigger**: Phase 1 `log_memory_op` was specified to "exit 0 with stderr message" on missing args. The verbatim function body wraps the entire body in `{ ... } 2>/dev/null`, which silences the `echo "missing args" >&2` call. Function exits 0 correctly but stderr is invisible — debug/development can't see why a call no-op'd.
- **Root cause**: Fail-open wrappers (`2>/dev/null || true`) are intentionally noisy-suppressing, but they conflict with diagnostic stderr inside the same function. The plan author wrote both "fail-open wrap everything" and "echo error to stderr" without recognizing the contradiction.
- **Rule**: When a function is fail-open (wraps body in `2>/dev/null`), do NOT include `echo ... >&2` for diagnostics inside the same wrapped block — they will be silenced. Either (a) drop the diagnostic, or (b) move the diagnostic outside the wrapper, or (c) log to a file (e.g., `~/.claude/auto-file-errors.log` pattern from Phase 4) instead of stderr. Document the choice explicitly in the plan.
- **Applies to**: all shell helper authoring, plan-coordinator, code-review-strict

### 2026-04-07: GNU `timeout` cannot wrap shell functions, and macOS has no /usr/bin/timeout
- **Trigger**: Phase 3 plan said "wrap `lint_all_projects` in `timeout 1800`" and "wrap each project in `timeout 300`". Plan-executor discovered both fail because GNU `timeout` only operates on processes, not shell functions — it cannot SIGTERM something that runs inside the same shell. Even at the launchd level, the QA-validator's first suggested fix (`/usr/bin/timeout 1800 /bin/bash daemon.sh`) was infeasible because macOS does NOT ship `/usr/bin/timeout` — only Homebrew's coreutils provides it at `/opt/homebrew/bin/timeout`, which is a fragile dependency for a launchd-managed daemon.
- **Root cause**: Two separate gaps. (1) Plan author treated `timeout` as if it worked like `trap ALRM` — which it does not. `timeout` forks and execs a child, sets up a SIGALRM, and waits. It cannot intercept a function call. (2) Plan author assumed POSIX `timeout` was universally available; macOS BSD userland does not include it. coreutils-via-Homebrew is the only source on macOS.
- **Rule**: For wall-clock budgets in shell scripts, use a self-watchdog: `( sleep $BUDGET && kill -TERM "$$" ) & WATCHDOG_PID=$!; trap 'kill "$WATCHDOG_PID" 2>/dev/null || true' EXIT`. This is portable, requires no external binary, runs from inside the script's own PID, and the EXIT trap cleans the sleeper on normal exit. For launchd jobs specifically, do NOT depend on `/usr/bin/timeout` (does not exist on macOS) or `/opt/homebrew/bin/timeout` (Homebrew path is fragile and not in launchd's default PATH). The self-watchdog approach is the only thing that survives all edge cases.
- **Applies to**: all shell daemon authoring, walter-planner, plan-coordinator, code-review-strict, anything macOS launchd

### 2026-04-07: Backup-once-per-call guards must use a function-local flag, not call-site dedupe
- **Trigger**: Phase 3 `fix_split` called `backup_memory_md "$dir"` once per file inside its outer loop. If two files in the same project both qualified for splitting, the second split's backup overwrote the first split's backup at `<dir>/.lint-backups/<TS>/MEMORY.md.fix_split`. The pre-first-split state of MEMORY.md was unrecoverable. Other fix functions (fix_title_only, fix_stale, fix_orphans, fix_broken_links) used a `_backed_up_memory=0` local flag to ensure backup ran once per function invocation; fix_split was missed during translation from plan to code.
- **Root cause**: The `backup_memory_md` helper deliberately uses `caller=${FUNCNAME[1]}` to derive the backup filename, so two calls from the SAME function in the SAME run produce IDENTICAL paths and `cp` overwrites silently. The backup-once contract is a function-level invariant, not a helper-level one. The plan documented the `_backed_up_memory=0` pattern explicitly for some functions but not for fix_split; the executor copy-pasted the helper call without the guard.
- **Rule**: Any function that may call `backup_memory_md` more than once per invocation MUST declare `local _backed_up_memory=0` at the top and gate every `backup_memory_md` call with `if [ "$_backed_up_memory" = "0" ]; then backup_memory_md "$dir"; _backed_up_memory=1; fi`. This must be enforced by code review for all 6 fix functions, not just the obvious ones. Add a smoke test: create 2 files of the same defect type in a test dir, run daemon, verify only ONE backup exists per fix-function name in `.lint-backups/<TS>/`.
- **Applies to**: memory-lint-daemon.sh, any future helper that derives output paths from FUNCNAME, code-review-strict

### 2026-04-07: Lock retry loops must record acquisition success in a flag, not rely on `&& break`
- **Trigger**: Phase 4 `write_memory_file` (background subshell of auto-file-answer.sh) had `for i in $(seq 1 20); do mkdir "$LOCKDIR" 2>/dev/null && break; sleep 0.5; done` followed by an unconditional `trap rmdir EXIT` and the rest of the function. If all 20 attempts failed (10s of mkdir contention), execution silently fell through without the lock and proceeded to call `log_memory_op` racing every other concurrent hook. The main hook body got this right by using `LOCK_ACQUIRED=0; ... && LOCK_ACQUIRED=1 && break; ...; [ "$LOCK_ACQUIRED" = "1" ] || exit 0`, but the function copy of the same pattern lost the flag and the gate. QA caught it as a Week 0 WARNING.
- **Root cause**: `&& break` exits the loop on success but provides no signal post-loop about WHY the loop ended. A loop that exhausts its retries vs one that breaks on first success look identical from outside. Without a separate boolean flag the post-loop code cannot distinguish "we have the lock" from "we gave up". This is the same trap as `for ... do something || break done` — the exit reason is lost.
- **Rule**: Every retry loop that protects a shared resource MUST set an `_ACQUIRED=0` flag before the loop and `_ACQUIRED=1 && break` inside the success branch, then guard the post-loop critical section with `[ "$_ACQUIRED" = "1" ] || exit 0` (or equivalent fail-open). Code-review-strict and qa-validator should explicitly look for `&& break` patterns in lock loops and flag them as bugs unless paired with an explicit acquisition flag check.
- **Applies to**: auto-file-answer.sh, any future shell-level lock retry, code-review-strict, qa-validator

### 2026-04-07: Glob patterns hardcoded to one prefix silently miss alternate-prefix dirs
- **Trigger**: Phase 3 `memory-lint-daemon.sh` `lint_all_projects` used `"$PROJECTS_BASE"/-Users-*/memory` to enumerate all opted-in projects. The glob caught 8 of 13 memory dirs on disk. The 5 missed ones (`-workspace`, `-workspace-airflow`, `-workspace-dw_airflow3`, `-workspace-playground`, `-workspace-ralphex-lite`) are real, distinct memory dirs created by Walter container sessions — when Claude Code runs inside the container, cwd is `/workspace/...` so the project entry name starts with `-workspace`, not `-Users-`. Stage 1 Day 1 dry-run audit caught it on the very first run. Without the staged rollout, this would have shipped to production and silently never linted half the memory dirs.
- **Root cause**: Author assumed all `~/.claude/projects/<id>` entries derive from host paths (`/Users/...`), missed that container sessions produce a parallel `-workspace*` namespace. The plan + REQUIREMENTS.md never enumerated the prefixes either — both implicitly inherited the assumption. Code review and QA-validator missed it because the test fixture only uses `-Users-*` paths.
- **Rule**: Any code that enumerates projects under `~/.claude/projects/` MUST handle both `-Users-*` (host) and `-workspace*` (Walter container) prefixes, OR document explicitly why one is excluded. Validation: `ls -d ~/.claude/projects/*/ | sed "s|.*/projects/||" | sort -u` shows the full prefix set. Add a smoke test that creates fixture dirs under both prefixes and asserts the enumeration touches both. The same rule applies to Phase 4 `auto-file-answer.sh` `resolve_memory_dir` — verify it correctly maps WALTER_HOST_PROJECT_DIR (or container cwd) to the `-workspace*` flavor when running inside the container.
- **Applies to**: memory-lint-daemon.sh, auto-file-answer.sh, intake.sh, any future memory-related glob across projects, code-review-strict, qa-validator
