#!/bin/bash
set -euo pipefail
# Detect stale nvim volume data after image rebuild and re-sync plugins/LSP/parsers.
# Uses a build stamp baked into the image vs. one stored in the volume.

IMAGE_STAMP="/opt/nvim-build-stamp"
VOLUME_STAMP="/home/node/.local/share/nvim/.nvim-build-stamp"

if [ ! -f "$IMAGE_STAMP" ]; then
    echo "No nvim build stamp found in image, skipping"
    exit 0
fi

IMAGE_TS=$(cat "$IMAGE_STAMP")
VOLUME_TS=$(cat "$VOLUME_STAMP" 2>/dev/null || echo "0")

if [ "$IMAGE_TS" = "$VOLUME_TS" ]; then
    echo "Nvim data is up-to-date (stamp: $IMAGE_TS)"
    exit 0
fi

echo "Nvim data is stale (image: $IMAGE_TS, volume: $VOLUME_TS), re-syncing..."

# 1. Sync Lazy plugins
echo "Syncing Lazy plugins..."
nvim --headless "+Lazy! sync" +qa 2>/dev/null || true

# 2. Multi-pass MasonInstall with filesystem-based polling
echo "Installing Mason packages..."
nvim --headless \
    -c 'lua (function()
      local pkgs = {"lua-language-server","bash-language-server","pyright","marksman","dockerfile-language-server","docker-compose-language-service","stylua","shfmt","shellcheck"}
      local mason_dir = vim.fn.stdpath("data") .. "/mason/packages/"
      local function is_pkg_installed(name) return vim.fn.isdirectory(mason_dir .. name) == 1 end
      local max_passes = 3
      local pass = 0
      local function run_pass()
        pass = pass + 1
        local missing = {}
        for _, name in ipairs(pkgs) do
          if not is_pkg_installed(name) then missing[#missing+1] = name end
        end
        if #missing == 0 then
          print("All " .. #pkgs .. " Mason packages installed")
          vim.cmd("qall"); return
        end
        if pass > max_passes then
          print("Max passes reached, " .. #missing .. " still missing: " .. table.concat(missing, ", "))
          vim.cmd("qall"); return
        end
        print("Pass " .. pass .. ": installing " .. #missing .. " packages: " .. table.concat(missing, ", "))
        vim.cmd("MasonInstall " .. table.concat(missing, " "))
        local timer = vim.uv.new_timer()
        local elapsed = 0
        timer:start(15000, 5000, vim.schedule_wrap(function()
          elapsed = elapsed + 5000
          local all_done = true
          for _, name in ipairs(missing) do
            if not is_pkg_installed(name) then all_done = false; break end
          end
          if all_done or elapsed >= 90000 then
            timer:stop(); timer:close()
            if not all_done then print("Pass " .. pass .. " timed out, retrying remaining...") end
            run_pass()
          end
        end))
      end
      vim.defer_fn(function()
        require("lazy").load({plugins={"mason.nvim","mason-lspconfig.nvim"}})
        vim.schedule(run_pass)
      end, 5000)
    end)()' \
    2>&1

# 3. Sync Treesitter parsers
echo "Syncing Treesitter parsers..."
nvim --headless \
    -c 'lua vim.defer_fn(function()
      require("lazy").load({plugins={"nvim-treesitter"}})
      vim.schedule(function()
        local langs = {"bash","python","lua","dockerfile","markdown","markdown_inline","json","yaml","toml","vim","vimdoc","regex","query"}
        vim.cmd("TSInstall " .. table.concat(langs, " "))
        local timer = vim.uv.new_timer()
        timer:start(15000, 5000, vim.schedule_wrap(function()
          local all_done = true
          for _, lang in ipairs(langs) do
            local ok = pcall(vim.treesitter.language.inspect, lang)
            if not ok then all_done = false; break end
          end
          if all_done then
            timer:stop(); timer:close()
            print("All treesitter parsers installed")
            vim.cmd("qall")
          end
        end))
        vim.defer_fn(function()
          timer:stop(); timer:close()
          print("TSInstall safety timeout reached")
          vim.cmd("qall")
        end, 120000)
      end)
    end, 3000)' \
    2>&1

# Update volume stamp
cp "$IMAGE_STAMP" "$VOLUME_STAMP"
echo "Nvim data re-sync complete"
