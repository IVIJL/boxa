#!/bin/bash
set -euo pipefail

# =============================================================================
# Grab a clipboard image (via clip-image.sh) and TYPE the resulting path into
# the currently focused window.
#
# For terminals that can run a command and inject its output themselves (e.g.
# WezTerm's action_callback) you don't need this — see docs/clipboard-images.md.
# For terminals without scripting (Alacritty, Ghostty, kitty, …) bind a key in
# your window manager / compositor to this script instead. Example (Hyprland):
#
#   bind = CTRL SHIFT, S, exec, ~/.local/share/boxa/scripts/clip-image-inject.sh
#
# Injection backend: wtype on Wayland, xdotool on X11, osascript on macOS.
#
# On macOS, prefer iTerm2's native "Run Coprocess" key binding (see
# docs/clipboard-images.md) — it injects the path with no extra tools and no
# Accessibility permission. This script's macOS path is for global-hotkey tools
# (Hammerspoon, skhd) and needs Accessibility access for keystroke injection.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

notify() {
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "boxa clip" "$1"
  else
    echo "boxa clip: $1" >&2
  fi
}

if ! output="$("$SCRIPT_DIR/clip-image.sh" 2>/dev/null)" || [ -z "$output" ]; then
  notify "No image in clipboard"
  exit 1
fi

# Strip trailing whitespace/newline from the path.
output="${output%"${output##*[![:space:]]}"}"

if [ "$(uname)" = "Darwin" ]; then
  # macOS: type into the frontmost app via System Events (needs Accessibility).
  osascript -e "tell application \"System Events\" to keystroke \"$output\""
elif [ -n "${WAYLAND_DISPLAY:-}" ] || [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
  if ! command -v wtype >/dev/null 2>&1; then
    notify "wtype not found (install wtype)"
    exit 1
  fi
  wtype -- "$output"
else
  if ! command -v xdotool >/dev/null 2>&1; then
    notify "xdotool not found (install xdotool)"
    exit 1
  fi
  xdotool type --clearmodifiers "$output"
fi
