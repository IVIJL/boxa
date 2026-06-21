-- Markdownlint: disable noisy rules (line length, duplicate headings)
return {
  "mfussenegger/nvim-lint",
  opts = {
    linters = {
      ["markdownlint-cli2"] = {
        args = { "--config", vim.fn.stdpath("config") .. "/.markdownlint-cli2.yaml", "--" },
      },
    },
  },
}
