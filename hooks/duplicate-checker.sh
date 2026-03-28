#!/bin/bash
# PostToolUse hook: warn if edited file has duplicates in sandbox/, test/
# Runs after Edit/Write. Outputs advisory text that Claude sees.
set -uo pipefail

HOOK_INPUT=$(cat)

FILE_PATH=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

BASENAME=$(basename "$FILE_PATH")

# Only check SQL, Python, JSON, YAML files
case "$BASENAME" in
    *.sql|*.py|*.json|*.yaml|*.yml) ;;
    *) exit 0 ;;
esac

# Search for duplicates in common copy locations
DUPES=""
for DIR in sandbox test staging tests; do
    if [ -d "/workspace/$DIR" ]; then
        FOUND=$(find "/workspace/$DIR" -name "$BASENAME" -not -path "$FILE_PATH" 2>/dev/null)
        [ -n "$FOUND" ] && DUPES="$DUPES $FOUND"
    fi
done

if [ -n "$DUPES" ]; then
    echo "WARNING: Found copies of $BASENAME that may need updating:$DUPES"
    echo "Check if these duplicates need the same changes applied."
fi

exit 0
