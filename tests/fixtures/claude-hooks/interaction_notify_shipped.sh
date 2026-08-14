#!/bin/bash

# Claude Code Interaction Request Hook
# Runs when Claude needs user interaction or approval

SOUND_FILE="/home/node/.claude/sounds/option.wav"
NTFY_URL="${NTFY_URL:-}"
TOKEN="${NTFY_TOKEN:-}"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INTERACTION_HOOK] $1" >> /home/node/.claude/hooks/notifications.log
}

# Check if this looks like an interaction request
# This hook runs on UserPromptSubmit, so we need to detect when Claude is asking for approval
INTERACTION_NEEDED=false

# Check for common interaction patterns in the user prompt
if [ -n "$USER_PROMPT" ]; then
    # Look for patterns that suggest Claude is waiting for approval
    if echo "$USER_PROMPT" | grep -qi "approve\|confirm\|proceed\|continue\|allow\|permission"; then
        INTERACTION_NEEDED=true
        log_message "Interaction pattern detected in user prompt"
    fi
fi

# Check if there are specific environment variables indicating interaction is needed
if [ -n "$CLAUDE_WAITING_FOR_APPROVAL" ] || [ -n "$HOOK_INTERACTION_NEEDED" ]; then
    INTERACTION_NEEDED=true
    log_message "Interaction flag detected in environment"
fi

# For now, we'll trigger on any UserPromptSubmit that contains certain keywords
# This might need refinement based on actual usage patterns
if echo "$*" | grep -qi "potvrdit\|schválit\|povolit\|souhlasit"; then
    INTERACTION_NEEDED=true
    log_message "Interaction keywords (cs) detected"
fi

# If interaction needed, send notification
if [ "$INTERACTION_NEEDED" = true ]; then
    # Play interaction sound (completely separate process)
    (
        if command -v paplay &> /dev/null; then
            nohup paplay "$SOUND_FILE" 2>/dev/null
        elif command -v aplay &> /dev/null; then
            nohup aplay "$SOUND_FILE" 2>/dev/null
        else
            log_message "No audio player found (paplay/aplay)"
        fi
    ) &

    # Send ntfy notification (separate process with timeout)
    MESSAGE="⏳ Claude is waiting for your confirmation"
    (
        if [ -n "$TOKEN" ] && [ -n "$NTFY_URL" ]; then
            curl -s -o /dev/null -H "Authorization: Bearer $TOKEN" -d "$MESSAGE" "$NTFY_URL"
        fi
    ) &

    log_message "Interaction notification sent: $MESSAGE"
fi

exit 0
