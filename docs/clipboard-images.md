# Clipboard images

Paste a screenshot straight into an agent. `boxa clip` grabs whatever image is
on your clipboard, saves it as a PNG, and prints a path your agent can read —
inside the container or on the host, the same path works in both.

## How it works

```bash
boxa clip
# → ~/.clipboard-images/clip-20260624-143012.png
```

1. The host's `~/.clipboard-images` directory is bind-mounted into **every**
   container at the same `~/.clipboard-images` path
   (`docker-run.sh` — see the `CLIPBOARD_DIR` mount). So the `~`-prefixed path
   `boxa clip` prints resolves identically on the host and inside any box.
2. `boxa clip` runs `scripts/clip-image.sh`, which detects your environment and
   pulls the raw image (or a copied image file) off the clipboard:
   - **WSL2** → Windows clipboard via PowerShell
   - **Wayland** → `wl-paste` (needs `wl-clipboard`)
   - **X11** → `xclip`
   - **macOS** → `pngpaste` if installed, else native `osascript` (no dependency)

   If no image is on the clipboard the command exits non-zero with
   `No image found in clipboard`.
3. Saved files land in `~/.clipboard-images/clip-<timestamp>.png` and are
   auto-pruned after 24 hours.

The printed path is all the agent needs — paste it into your Claude Code (or any
agent) prompt and it can read the image directly from the bind-mounted directory.

> **Note:** the clipboard grab needs host clipboard access (PowerShell /
> `wl-paste` / `xclip`), so `clip-image.sh` must run **on the host**, not inside
> the container. The terminal keybindings below all invoke the host-side script.

## Terminal setup

The smooth experience is a single keypress: grab the image and type its path
into whatever has focus (e.g. the agent prompt). Whether your terminal can do
that depends on whether it can run a command and inject its output.

### WezTerm (single keypress — recommended)

WezTerm's `action_callback` can run the host script and `send_text` its output
into the focused pane. Add this to your `~/.wezterm.lua` keybindings (Ctrl+Shift+S):

```lua
{
  key = "s",
  mods = "CTRL|SHIFT",
  action = wezterm.action_callback(function(window, pane)
    local cmd

    if wezterm.target_triple:find("windows") then
      -- Windows/WSL: call the script via wsl.exe (default distro)
      cmd = {
        "wsl.exe", "--", "bash", "-lc",
        "$HOME/.local/share/boxa/scripts/clip-image.sh",
      }
    else
      cmd = { os.getenv("HOME") .. "/.local/share/boxa/scripts/clip-image.sh" }
    end

    local success, stdout, _ = wezterm.run_child_process(cmd)

    if success then
      pane:send_text(stdout:gsub("%s+$", "")) -- strip trailing newline
    else
      window:toast_notification("boxa clip", "No image in clipboard", nil, 3000)
    end
  end),
},
```

Copy an image, focus the agent prompt, press **Ctrl+Shift+S** — the path appears,
ready to send.

> Upgrading from devbox? The script moved with the rename. Make sure the path is
> `~/.local/share/boxa/scripts/clip-image.sh` (the old `devbox clip` command and
> the `~/.local/share/devbox` checkout are removed by `migrate-from-devbox.sh`).

Terminals other than WezTerm can't capture a command's output and inject it
themselves. The workaround is `scripts/clip-image-inject.sh`: it grabs the image
and **types the path into the focused window** (`wtype` on Wayland, `xdotool` on
X11). You just need a key that runs it — either from the terminal's own config
(if it can spawn a command) or from your window manager (if it can't). Install
the injector tool first: `wtype` for Wayland, `xdotool` for X11.

### Alacritty / kitty — spawn from the terminal config

Alacritty can fork a program straight from a keybinding (`command`), so no window
manager is involved. `alacritty.toml` (Ctrl+Shift+S):

```toml
[[keyboard.bindings]]
key = "S"
mods = "Control|Shift"
command = { program = "/home/you/.local/share/boxa/scripts/clip-image-inject.sh" }
```

> `command.program` is exec'd directly, **not** through a shell, so `~` and `$HOME`
> are **not** expanded — use an absolute path, or wrap it:
> `command = { program = "bash", args = ["-lc", "$HOME/.local/share/boxa/scripts/clip-image-inject.sh"] }`.

kitty has the equivalent via its `launch` action in `kitty.conf`:

```conf
map ctrl+shift+s launch --type=background ~/.local/share/boxa/scripts/clip-image-inject.sh
```

### Ghostty (or any terminal that can't spawn) — bind in your window manager

Ghostty keybinds can only trigger built-in actions or send literal text — they
can't run a command. Bind the key in your **window manager / compositor** instead
and point it at the same inject script.

**Hyprland** (e.g. Omarchy) — `~/.config/hypr/hyprland.conf`:

```ini
bind = CTRL SHIFT, S, exec, ~/.local/share/boxa/scripts/clip-image-inject.sh
```

The same idea applies to Sway (`bindsym`), i3, etc. Since the keybind lives at the
WM level it works regardless of which terminal is focused.

Copy an image, focus the agent prompt, press **Ctrl+Shift+S** — the path is typed
in, ready to send.

### macOS — iTerm2, WezTerm, or Hammerspoon

`boxa clip` works on macOS out of the box (`pngpaste` if installed, otherwise the
built-in `osascript`). For the keybinding, **the recommended path is a global
hotkey via [Hammerspoon](https://www.hammerspoon.org/)** — it works in *every*
terminal at once (including Terminal.app, which can't run a command from a
keybind), and `install.sh` sets it up for you. See the
[Hammerspoon section below](#hammerspoon--terminalapp-recommended-set-up-by-installsh).
The iTerm2 / WezTerm bindings below are alternatives if you'd rather keep the
hotkey scoped to one terminal.

**iTerm2** — iTerm2 can run a *coprocess*
from a key binding, and a coprocess's stdout is injected into the session as if
typed. Settings → Keys → Key Bindings → **+**:

- Shortcut: **⌃⇧S**
- Action: **Run Coprocess…**
- Command: `~/.local/share/boxa/scripts/clip-image.sh | tr -d '\n'`

(`tr -d '\n'` drops the trailing newline so the path isn't auto-submitted.)

**WezTerm** — the [Lua callback above](#wezterm-single-keypress--recommended)
works on macOS unchanged (the non-Windows branch calls the script directly).

#### Hammerspoon / Terminal.app (recommended, set up by `install.sh`)

Terminal.app can't run a command from a keybinding, so the cross-terminal
answer is a global hotkey via [Hammerspoon](https://www.hammerspoon.org/).
`install.sh` automates the whole thing on macOS:

- `brew install --cask hammerspoon` + `brew install terminal-notifier pngpaste`
  (idempotent — skipped if already present).
- A **managed block** is written into `~/.hammerspoon/init.lua` between
  `-- >>> boxa clipboard-image (managed) >>>` markers. It only touches the
  block between the markers, so a hand-written `init.lua` survives intact;
  re-running replaces the block rather than duplicating it. The block binds
  Ctrl+Shift+S to run `clip-image.sh` and type its output into the focused
  window.

Two GUI steps macOS won't let any script do for you — `install.sh` opens the
right panels and tells you what to click:

1. **Accessibility** — System Settings → Privacy & Security → Accessibility →
   enable **Hammerspoon**. Without it, Ctrl+Shift+S fails *silently*: the PNG
   is saved but the path is never typed. Note: a running Hammerspoon caches
   its trust state, so `install.sh` restarts it after triggering the prompt.
   If Hammerspoon is already ticked but injection still doesn't work, toggle
   it off/on (or remove it with **−** and re-add with **+**).
2. **Notifications → Alerts** — for clickable harvest-log notifications
   (`terminal-notifier`), find **terminal-notifier** in System Settings →
   Notifications and switch its style from **Banners** to **Alerts** so
   reports stay on screen until acknowledged. (Persistence can't be set
   programmatically — `ncprefs` is protected and its flag encoding shifts
   between macOS releases.)

If you'd rather wire it by hand, the managed block is just:

```lua
require("hs.ipc")
local CLIP_SCRIPT = os.getenv("HOME") .. "/.local/share/boxa/scripts/clip-image.sh"
hs.hotkey.bind({ "ctrl", "shift" }, "s", function()
  local out = hs.execute(CLIP_SCRIPT, true)
  out = (out or ""):gsub("%s+$", "")
  if out ~= "" then
    hs.eventtap.keyStrokes(out)
  else
    hs.alert.show("boxa clip: žádný obrázek v clipboardu")
  end
end)
```

Keystroke injection (Hammerspoon, or `clip-image-inject.sh`'s macOS path via
skhd) needs Accessibility permission — macOS prompts on first use. iTerm2's
coprocess and the WezTerm callback don't.

### Any terminal (zero config)

Just run `boxa clip` (host) or `~/.local/share/boxa/scripts/clip-image.sh`,
then copy the printed path and paste it into your agent.

## See also

- [Editors](editors.md) — attaching VS Code / Cursor to a box.
- [Networking & port routing](networking.md) — dev URLs for reaching apps.
