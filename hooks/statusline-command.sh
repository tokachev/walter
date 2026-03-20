#!/bin/sh
input=$(cat)
model=$(echo "$input" | jq -r '.model.display_name')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
transcript=$(echo "$input" | jq -r '.transcript_path // empty')

# Context usage
if [ -n "$used" ]; then
  ctx_str="ctx:${used}%"
else
  ctx_str="ctx:-"
fi

# Session duration via transcript file ctime (Linux stat)
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  file_epoch=$(stat -c %W "$transcript" 2>/dev/null)
  # %W = birth time; fallback to %Y (mtime) if birth time is 0 or unavailable
  if [ -z "$file_epoch" ] || [ "$file_epoch" = "0" ]; then
    file_epoch=$(stat -c %Y "$transcript" 2>/dev/null)
  fi
  now_epoch=$(date +%s)
  if [ -n "$file_epoch" ] && [ "$file_epoch" -gt 0 ] 2>/dev/null; then
    elapsed_min=$(( (now_epoch - file_epoch) / 60 ))
    time_str="${elapsed_min}m"
  else
    time_str="-"
  fi
else
  time_str="-"
fi

printf "\033[33mwalter\033[0m | %s | %s | %s" "$model" "$ctx_str" "$time_str"
