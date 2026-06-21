-- Python LSP: use python-lsp-server installed via uv tool (not Mason)
return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        pylsp = {
          mason = false,
          settings = {
            pylsp = {
              plugins = {
                -- formatting
                black = { enabled = true },
                isort = { enabled = true },
                -- type checking
                pylsp_mypy = {
                  enabled = true,
                  live_mode = false,
                  dmypy = true,
                  report_progress = true,
                  overrides = function()
                    local root = vim.fn.getcwd()
                    return { "--python-executable", vim.fn.exepath("python3"), "--namespace-packages", "--explicit-package-bases", true }
                  end,
                },
                -- disable defaults replaced by mypy
                pycodestyle = { enabled = false },
                pyflakes = { enabled = false },
                mccabe = { enabled = false },
                -- auto-detect virtualenv
                pylsp_venv = (function()
                  local venv = vim.env.VIRTUAL_ENV
                    or (vim.uv.fs_stat("venv") and vim.fn.getcwd() .. "/venv")
                    or (vim.uv.fs_stat(".venv") and vim.fn.getcwd() .. "/.venv")
                  if venv then
                    return { enabled = true, venv_path = venv }
                  end
                  return { enabled = false }
                end)(),
              },
            },
          },
        },
      },
    },
  },
}
