#!/usr/bin/env bash
set -euo pipefail

# gsd/picker.sh — Interactive fzf picker with graceful fallback
#
# Usage:
#   echo -e "Option A\nOption B\nOption C" | bash gsd/picker.sh "Which approach?"
#   echo -e "Option A\nOption B" | bash gsd/picker.sh --multi "Select features:"
#
# Behavior:
#   - If fzf is available and stdin is a tty: interactive fzf picker
#   - If no tty (non-interactive): returns first option (or all if --multi)
#   - If no fzf: numbered list with read prompt
#   - Always appends "Other (свой ответ)" as the last option
#   - --multi flag enables multi-select (fzf -m / multiple numbered choices)

MULTI=false
if [[ "${1:-}" == "--multi" ]]; then
    MULTI=true
    shift
fi

HEADER="${1:-Choose an option:}"

# Read options from stdin into array
OPTIONS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && OPTIONS+=("$line")
done

if [[ ${#OPTIONS[@]} -eq 0 ]]; then
    echo "Error: no options provided" >&2
    exit 1
fi

# Append "Other" as last option
OPTIONS+=("Other (свой ответ)")

# Non-interactive mode: no tty — return first option (skip "Other")
if [[ ! -t 0 && ! -t 1 ]] || [[ ! -t 2 ]]; then
    # Check if we're being piped to AND have no terminal
    if [[ ! -t 1 ]]; then
        if $MULTI; then
            printf '%s\n' "${OPTIONS[@]:0:${#OPTIONS[@]}-1}"
        else
            echo "${OPTIONS[0]}"
        fi
        exit 0
    fi
fi

pick_with_fzf() {
    local fzf_opts=(
        --header="$HEADER"
        --height=~40%
        --layout=reverse
        --border
        --no-sort
    )
    $MULTI && fzf_opts+=(-m)

    local result
    result=$(printf '%s\n' "${OPTIONS[@]}" | fzf "${fzf_opts[@]}") || true

    if [[ -z "$result" ]]; then
        # User cancelled — return empty
        return 1
    fi

    # Handle "Other" selection
    if echo "$result" | grep -qF "Other (свой ответ)"; then
        echo "$HEADER" >&2
        read -r -p "> " custom_answer </dev/tty
        echo "$custom_answer"
    else
        echo "$result"
    fi
}

pick_with_numbered_list() {
    echo "" >&2
    echo "$HEADER" >&2
    echo "" >&2

    local i=1
    for opt in "${OPTIONS[@]}"; do
        echo "  $i) $opt" >&2
        ((i++))
    done
    echo "" >&2

    if $MULTI; then
        read -r -p "Enter numbers separated by spaces (e.g. 1 3): " choices </dev/tty
        for num in $choices; do
            local idx=$((num - 1))
            if [[ $idx -ge 0 && $idx -lt ${#OPTIONS[@]} ]]; then
                if [[ "${OPTIONS[$idx]}" == "Other (свой ответ)" ]]; then
                    read -r -p "Your answer: " custom_answer </dev/tty
                    echo "$custom_answer"
                else
                    echo "${OPTIONS[$idx]}"
                fi
            fi
        done
    else
        read -r -p "Enter number: " choice </dev/tty
        local idx=$((choice - 1))
        if [[ $idx -ge 0 && $idx -lt ${#OPTIONS[@]} ]]; then
            if [[ "${OPTIONS[$idx]}" == "Other (свой ответ)" ]]; then
                read -r -p "Your answer: " custom_answer </dev/tty
                echo "$custom_answer"
            else
                echo "${OPTIONS[$idx]}"
            fi
        else
            echo "Invalid choice" >&2
            return 1
        fi
    fi
}

# Pick strategy
if command -v fzf &>/dev/null && [[ -t 2 ]]; then
    pick_with_fzf
else
    pick_with_numbered_list
fi
