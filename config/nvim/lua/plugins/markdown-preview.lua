-- markdown-preview.nvim: fix for Docker/WSL2 (no cmd.exe browser)
-- Server listens on 0.0.0.0:8090, accessible via Traefik proxy from host
return {
  "iamcco/markdown-preview.nvim",
  init = function()
    vim.g.mkdp_open_to_the_world = 1
    vim.g.mkdp_port = 8090
    vim.g.mkdp_echo_preview_url = 0
    vim.g.mkdp_browser = ""
    vim.g.mkdp_browserfunc = "MkdpOpenPreview"

    vim.cmd([[
      function! MkdpOpenPreview(url) abort
        let l:path = substitute(a:url, 'http://[^/]*', '', '')
        let l:host = '8090.' . hostname() . '.127.0.0.1.traefik.me'
        let l:preview_url = 'http://' . l:host . l:path
        execute 'lua vim.notify("' . l:preview_url . '", vim.log.levels.INFO)'
      endfunction
    ]])
  end,
}
