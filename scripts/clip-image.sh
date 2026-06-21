#!/bin/bash
set -euo pipefail

# =============================================================================
# Grab clipboard image and save to ~/.clipboard-images/
# Works on WSL2, Linux X11, and Linux Wayland.
# =============================================================================

CLIP_DIR="${HOME}/.clipboard-images"
mkdir -p "$CLIP_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
FILENAME="clip-${TIMESTAMP}.png"
HOST_PATH="${CLIP_DIR}/${FILENAME}"

# --- Detect environment and grab clipboard image ----------------------------

if grep -qi microsoft /proc/version 2>/dev/null; then
  # WSL2: use Windows clipboard via PowerShell
  WIN_PATH=$(wslpath -w "$HOST_PATH")
  if ! powershell.exe -NoProfile -Command "
Add-Type -AssemblyName System.Windows.Forms
\$img = [System.Windows.Forms.Clipboard]::GetImage()
if (\$img -eq \$null) {
    Write-Error 'No image in clipboard'
    exit 1
}
\$img.Save('${WIN_PATH}')
" 2>/dev/null; then
    echo "ERROR: No image found in clipboard" >&2
    exit 1
  fi

elif [ "${XDG_SESSION_TYPE:-}" = "wayland" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
  # Wayland: use wl-paste
  if ! command -v wl-paste >/dev/null 2>&1; then
    echo "ERROR: wl-paste not found (install wl-clipboard)" >&2
    exit 1
  fi

  # Check if a file was copied (like from Nautilus)
  if wl-paste -l 2>/dev/null | grep -q "text/uri-list"; then
    URI=$(wl-paste -t text/uri-list 2>/dev/null | head -n 1 || true)
    FILE_PATH=$(echo "$URI" | sed 's/^file:\/\///' | tr -d '\r')
    FILE_PATH=$(printf '%b' "${FILE_PATH//%/\\x}") # Decode URL encoding (spaces, etc.)

    if file --mime-type "$FILE_PATH" | grep -q "image/"; then
      cp "$FILE_PATH" "$HOST_PATH"
    else
      echo "ERROR: Copied file is not an image" >&2
      exit 1
    fi
  # Fallback to raw pixels (Browser, Screenshot)
  elif ! wl-paste --type image/png >"$HOST_PATH" 2>/dev/null; then
    rm -f "$HOST_PATH"
    echo "ERROR: No image found in clipboard" >&2
    exit 1
  fi

else
  # X11: use xclip
  if ! command -v xclip >/dev/null 2>&1; then
    echo "ERROR: xclip not found (install xclip)" >&2
    exit 1
  fi

  # Check if a file was copied (like from Nautilus)
  if xclip -selection clipboard -t TARGETS -o 2>/dev/null | grep -q "text/uri-list"; then
    URI=$(xclip -selection clipboard -t text/uri-list -o 2>/dev/null | head -n 1 || true)
    FILE_PATH=$(echo "$URI" | sed 's/^file:\/\///' | tr -d '\r')
    FILE_PATH=$(printf '%b' "${FILE_PATH//%/\\x}") # Decode URL encoding (spaces, etc.)

    if file --mime-type "$FILE_PATH" | grep -q "image/"; then
      cp "$FILE_PATH" "$HOST_PATH"
    else
      echo "ERROR: Copied file is not an image" >&2
      exit 1
    fi
  # Fallback to raw pixels (Browser, Screenshot)
  elif ! xclip -selection clipboard -target image/png -o >"$HOST_PATH" 2>/dev/null; then
    rm -f "$HOST_PATH"
    echo "ERROR: No image found in clipboard" >&2
    exit 1
  fi
fi

# --- Validate output ---------------------------------------------------------

if [ ! -s "$HOST_PATH" ]; then
  rm -f "$HOST_PATH"
  echo "ERROR: Failed to save clipboard image" >&2
  exit 1
fi

# Clean up images older than 24 hours
find "$CLIP_DIR" -name 'clip-*.png' -mmin +1440 -delete 2>/dev/null || true

# Output path with ~ (works on both host and inside container via bind mount)
# shellcheck disable=SC2088
echo "~/.clipboard-images/${FILENAME}"
