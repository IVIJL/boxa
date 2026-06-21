#!/bin/bash

# Claude Code Question/Permission Notification Hook
# Runs when Claude needs permission or asks questions

SOUND_FILE="/home/node/.claude/sounds/option.wav"
NTFY_URL="${NTFY_URL:-}"
TOKEN="${NTFY_TOKEN:-}"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [QUESTION_HOOK] $1" >> /home/node/.claude/hooks/notifications.log
}

# Play question sound (completely separate process)
(
    if command -v paplay &> /dev/null; then
        nohup paplay "$SOUND_FILE" 2>/dev/null
    elif command -v aplay &> /dev/null; then
        nohup aplay "$SOUND_FILE" 2>/dev/null
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') [QUESTION_HOOK] No audio player found" >> /home/node/.claude/hooks/notifications.log
    fi
) &

# Send ntfy notification (separate process with timeout)
MESSAGE="❓ Claude has a question or needs permission"
(
    if [ -n "$TOKEN" ] && [ -n "$NTFY_URL" ]; then
        curl -s -o /dev/null -H "Authorization: Bearer $TOKEN" -d "$MESSAGE" "$NTFY_URL"
    fi
) &

log_message "Question notification sent: $MESSAGE"

exit 0
