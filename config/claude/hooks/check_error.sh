#!/bin/bash

# Claude Code Error Detection Hook
# Runs after tool use to detect errors and failures

SOUND_FILE="/home/node/.claude/sounds/fail.wav"
NTFY_URL="${NTFY_URL:-}"
TOKEN="${NTFY_TOKEN:-}"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR_HOOK] $1" >> /home/node/.claude/hooks/notifications.log
}

# Read JSON input from Claude Code (PostToolUse hook)
ERROR_DETECTED=false
INPUT=""

# Read input safely with timeout to prevent hanging
if [ ! -t 0 ]; then
    # Use timeout to prevent hanging, read available data
    INPUT=$(timeout 2s cat 2>/dev/null || echo "")
    log_message "Received input: $INPUT"
fi

# Parse JSON and check for errors in tool_response
if [ -n "$INPUT" ]; then
    # Extract tool_name first
    TOOL_NAME=$(echo "$INPUT" | grep -o '"tool_name":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")

    # For debugging - log the full input for Bash tool
    if [ "$TOOL_NAME" = "Bash" ]; then
        log_message "BASH TOOL DEBUG - Full input: $INPUT"
    fi

    # Try different approaches to extract tool_response
    # Method 1: Simple string response
    TOOL_RESPONSE=$(echo "$INPUT" | grep -o '"tool_response":"[^"]*"' | cut -d'"' -f4 | sed 's/\\n/\n/g' 2>/dev/null || echo "")

    # Method 2: Check if tool_response contains an error field
    TOOL_ERROR_FIELD=$(echo "$INPUT" | grep -o '"tool_response":[^}]*"error":[^}]*}' 2>/dev/null || echo "")

    # Method 3: Look for error anywhere in the entire JSON for Bash tool
    if [ "$TOOL_NAME" = "Bash" ]; then
        # For Bash, search the entire JSON for error patterns
        if echo "$INPUT" | grep -qi "command not found\|permission denied\|no such file\|failed\|error"; then
            ERROR_DETECTED=true
            log_message "Error pattern detected in Bash tool JSON"
        fi
    fi

    log_message "Tool: $TOOL_NAME, Response: $TOOL_RESPONSE, Error field: $TOOL_ERROR_FIELD"

    # Check for error patterns in tool response (non-Bash tools)
    if [ "$TOOL_NAME" != "Bash" ] && echo "$TOOL_RESPONSE" | grep -qi "error\|failed\|exception\|traceback\|fatal\|command not found\|permission denied"; then
        ERROR_DETECTED=true
        log_message "Error pattern detected in tool response"
    fi

    # Check if tool response indicates error field exists
    if echo "$INPUT" | grep -q '"error":'; then
        ERROR_DETECTED=true
        log_message "Tool response contains error field"
    fi

    # Special check for Bash tool error field
    if [ -n "$TOOL_ERROR_FIELD" ]; then
        ERROR_DETECTED=true
        log_message "Tool response contains error field in object"
    fi
fi

# Fallback check for environment variables
if [ -n "$CLAUDE_TOOL_ERROR" ] || [ -n "$HOOK_ERROR_DETECTED" ]; then
    ERROR_DETECTED=true
    log_message "Error flag detected in environment"
fi

# If error detected, send notification
if [ "$ERROR_DETECTED" = true ]; then
    # Play error sound (completely separate process)
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
    MESSAGE="❌ Claude hit an error while using a tool"
    if [ -n "$TOOL_NAME" ]; then
        MESSAGE="❌ Claude hit an error while using: $TOOL_NAME"
    fi
    log_message "Sending notification: $MESSAGE"
    (
        if [ -n "$TOKEN" ] && [ -n "$NTFY_URL" ]; then
            curl -s -o /dev/null -H "Authorization: Bearer $TOKEN" -d "$MESSAGE" "$NTFY_URL"
        fi
    ) &

    log_message "Error notification sent: $MESSAGE"
fi

exit 0
