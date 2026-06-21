local env = vim.env
local opt = vim.opt
local exe = vim.fn.executable
local uv = vim.uv or vim.loop

-- detekce prostředí
local has_wayland = env.WAYLAND_DISPLAY and exe("wl-copy") == 1 and exe("wl-paste") == 1

-- X11: pokud DISPLAY je ve tvaru ":0" (unix socket), vyžaduj existenci X0 socketu
local function x11_socket_ok()
  local display = env.DISPLAY or ""
  if display:match("^:") then
    return uv.fs_stat("/tmp/.X11-unix/X0") or uv.fs_stat("/mnt/wslg/.X11-unix/X0")
  end
  return true
end

local has_x11 = env.DISPLAY
  and (exe("xclip") == 1 or exe("xsel") == 1)
  and x11_socket_ok()

-- helper: paste s odstraněním CR
local function paste_clean(cmd)
  return function()
    local handle = io.popen(cmd)
    if not handle then
      return { { "" }, "v" }
    end
    local text = handle:read("*a") or ""
    handle:close()

    -- strip Windows CR
    text = text:gsub("\r", "")

    local lines = vim.split(text, "\n", { plain = true })
    return { lines, "v" }
  end
end

-- helper: OSC52 paste z registru 0 + strip CR
local function paste_from_reg(regname)
  return function()
    local text = vim.fn.getreg(regname)
    text = text:gsub("\r", "")
    local lines = vim.split(text, "\n", { plain = true })
    return { lines, vim.fn.getregtype(regname) }
  end
end

-- =============================
-- WAYLAND
-- =============================
if has_wayland then
  opt.clipboard = "unnamedplus"

  vim.g.clipboard = {
    name = "Wayland (wl-clipboard, clean CR)",
    copy = {
      ["+"] = "wl-copy",
      ["*"] = "wl-copy",
    },
    paste = {
      ["+"] = paste_clean("wl-paste"),
      ["*"] = paste_clean("wl-paste"),
    },
  }

-- =============================
-- X11 (MobaXterm, forwarding)
-- =============================
elseif has_x11 then
  opt.clipboard = "unnamedplus"

  local copy_cmd = exe("xclip") == 1
      and "xclip -selection clipboard -i"
      or "xsel --clipboard --input"

  local paste_cmd = exe("xclip") == 1
      and "xclip -selection clipboard -o"
      or "xsel --clipboard --output"

  vim.g.clipboard = {
    name = "X11 clipboard (clean CR)",
    copy = {
      ["+"] = copy_cmd,
      ["*"] = copy_cmd,
    },
    paste = {
      ["+"] = paste_clean(paste_cmd),
      ["*"] = paste_clean(paste_cmd),
    },
  }

-- =============================
-- OSC52 fallback (SSH / WezTerm)
-- =============================
else
  opt.clipboard = "unnamedplus"

  local osc52 = require("vim.ui.clipboard.osc52")

  local function osc52_copy(reg)
    local f = osc52.copy(reg)
    return function(lines, regtype)
      if not pcall(f, lines, regtype) then
        pcall(f, lines)
      end
    end
  end

  vim.g.clipboard = {
    name = "OSC52 (copy-only; paste from reg0, clean CR)",
    copy = {
      ["+"] = osc52_copy("+"),
      ["*"] = osc52_copy("*"),
    },
    paste = {
      ["+"] = paste_from_reg("0"),
      ["*"] = paste_from_reg("0"),
    },
  }
end
