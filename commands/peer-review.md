---
description: "Peer review via OpenAI Codex: get a second opinion on code at a given path"
allowed-tools: Bash, Read, Glob, Grep
---

# Peer Review via Codex

Dispatch code to OpenAI Codex CLI for independent second opinion, then compare findings.

## Input

`$ARGUMENTS` — path to file or directory to review. Examples:
- `src/main.py`
- `src/utils/`
- `src/main.py src/config.py` (multiple files)

## Step 1: Read the Code

Read all files at the given path(s). If a directory — glob for source files and read them.
Form your own opinion: bugs, logic errors, security issues, performance, design problems.
Keep your findings as internal notes (don't output yet).

## Step 2: Dispatch to Codex

Use `codex exec` with sandbox disabled (walter's Docker container already provides isolation).
List the file paths in the prompt — Codex reads them directly.

```bash
codex exec -s danger-full-access <<'EOF' 2>&1
Review the following files for bugs, logic errors, security issues, performance problems, and design issues. Be specific — reference file names and line numbers.

Files to review:
- path/to/file1.ext
- path/to/file2.ext

Read each file and provide detailed findings.
EOF
```

For a directory:
```bash
codex exec -s danger-full-access <<'EOF' 2>&1
Review all source files in path/to/dir/ for bugs, logic errors, security issues, performance problems, and design issues. Be specific — reference file names and line numbers.

List the directory, read each source file, and provide detailed findings.
EOF
```

IMPORTANT:
- Always use `-s danger-full-access` — default sandbox blocks filesystem reads via Landlock
- Use heredoc `<<'EOF'` for the prompt (single-quoted delimiter avoids shell expansion issues)
- Let Codex read files itself — do NOT embed file contents in the prompt

## Step 3: Compare & Synthesize

Compare your analysis with Codex's response:

- **Agreement** — both found the same issue → high confidence
- **Complementary** — one found something the other missed → include, note source
- **Disagreement** — conflicting opinions → present both sides with reasoning

## Step 4: Present Results

```
## Peer Review Results

### Agreed Issues
(issues both reviewers flagged — highest confidence)

### Additional Findings
**Claude:** ...
**Codex:** ...

### Disagreements (if any)
Claude's position: ...
Codex's position: ...
```

Keep it concise. No filler.

User input: $ARGUMENTS
