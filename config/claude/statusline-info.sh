#!/bin/bash

# Read JSON input from stdin
input=$(cat)

# Extract data from JSON
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')
current_dir=$(echo "$input" | jq -r '.workspace.current_dir // "~"')
project_dir=$(echo "$input" | jq -r '.workspace.project_dir // ""')

# Get folder name (project name or current directory basename)
if [ -n "$project_dir" ] && [ "$project_dir" != "null" ]; then
    folder_name=$(basename "$project_dir")
else
    folder_name=$(basename "$current_dir")
fi

# Git branch (suppress error messages)
git_branch=""
if git -C "$current_dir" rev-parse --git-dir >/dev/null 2>&1; then
    git_branch=$(git -C "$current_dir" branch --show-current 2>/dev/null || echo "")
    if [ -n "$git_branch" ]; then
        git_branch=" [${git_branch}]"
    fi
fi

# Context window usage
pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')

# Context size label
if [ "$ctx_size" -ge 900000 ] 2>/dev/null; then
    ctx_label="1M"
elif [ "$ctx_size" -ge 180000 ] 2>/dev/null; then
    ctx_label="200K"
else
    ctx_label="$((ctx_size / 1000))K"
fi

# Color based on usage: green <50%, yellow 50-80%, red >80%
if [ "$pct" -ge 80 ] 2>/dev/null; then
    bar_color='\033[31m'
elif [ "$pct" -ge 50 ] 2>/dev/null; then
    bar_color='\033[33m'
else
    bar_color='\033[32m'
fi

# Progress bar (10 chars)
filled=$((pct / 10))
empty=$((10 - filled))
bar=""
if [ "$filled" -gt 0 ]; then
    printf -v fill_str "%${filled}s"
    bar="${fill_str// /█}"
fi
if [ "$empty" -gt 0 ]; then
    printf -v empty_str "%${empty}s"
    bar="${bar}${empty_str// /░}"
fi

# Session duration from cost.total_duration_ms
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
duration_sec=$((duration_ms / 1000))
if [ "$duration_sec" -lt 60 ]; then
    duration="${duration_sec}s"
elif [ "$duration_sec" -lt 3600 ]; then
    duration="$((duration_sec / 60))m"
else
    duration="$((duration_sec / 3600))h$(((duration_sec % 3600) / 60))m"
fi

# Line 1: model, project, git branch
printf "\033[36m%s\033[0m \033[33m%s\033[0m\033[32m%s\033[0m\n" \
    "$model_name" "$folder_name" "$git_branch"

# 5-hour rate limit window
five_h_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' | cut -d. -f1)
five_h_info=""
if [ -n "$five_h_pct" ]; then
    remaining=$((100 - five_h_pct))
    if [ "$five_h_pct" -ge 80 ] 2>/dev/null; then
        five_h_color='\033[31m'
    elif [ "$five_h_pct" -ge 50 ] 2>/dev/null; then
        five_h_color='\033[33m'
    else
        five_h_color='\033[32m'
    fi
    # Time until 5h window resets
    resets_at=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
    reset_label=""
    if [ -n "$resets_at" ]; then
        now=$(date +%s)
        left=$((resets_at - now))
        if [ "$left" -gt 0 ]; then
            left_h=$((left / 3600))
            left_m=$(((left % 3600) / 60))
            if [ "$left_h" -gt 0 ]; then
                reset_label=" ${left_h}h${left_m}m"
            else
                reset_label=" ${left_m}m"
            fi
        fi
    fi
    five_h_info=$(printf " %b5h:%d%%free%s\033[0m" "$five_h_color" "$remaining" "$reset_label")
fi

# Line 2: context bar, percentage, ctx size, duration, 5h window
printf "%b%s\033[0m %d%% [%s] \033[35m⏱ %s\033[0m%s" \
    "$bar_color" "$bar" "$pct" "$ctx_label" "$duration" "$five_h_info"
