-- Treesitter: fix parser install dir and deduplicate ensure_installed
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      -- Use a user-writable parser install directory
      opts.parser_install_dir = vim.fn.stdpath("data") .. "/site"

      -- Prepend to runtimepath so our parsers are found first
      vim.opt.runtimepath:prepend(opts.parser_install_dir)

      -- Deduplicate ensure_installed to prevent parallel install race conditions
      if opts.ensure_installed and type(opts.ensure_installed) == "table" then
        local seen = {}
        local deduped = {}
        for _, lang in ipairs(opts.ensure_installed) do
          if not seen[lang] then
            seen[lang] = true
            deduped[#deduped + 1] = lang
          end
        end
        opts.ensure_installed = deduped
      end
    end,
  },
}
