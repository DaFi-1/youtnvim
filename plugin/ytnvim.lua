if vim.g.loaded_ytnvim then
  return
end
vim.g.loaded_ytnvim = 1

local yt = require("ytnvim")

vim.api.nvim_create_user_command("YTNvim", function(opts)
  if opts.args and opts.args ~= "" then
    yt.open(opts.args)
  else
    yt.open()
  end
end, { nargs = "*", desc = "Abrir interface do YTNvim" })

vim.api.nvim_create_user_command("YTSearch", function(opts)
  if opts.args and opts.args ~= "" then
    yt.open(opts.args)
  else
    yt.prompt_search()
  end
end, { nargs = "*", desc = "Pesquisar vídeos no YouTube com YTNvim" })

vim.api.nvim_create_user_command("YTToggle", function()
  yt.toggle()
end, { desc = "Alternar interface do YTNvim" })

vim.api.nvim_create_user_command("YTStop", function()
  yt.stop()
end, { desc = "Parar reprodução no YTNvim" })

vim.api.nvim_create_user_command("YTPause", function()
  yt.toggle_pause()
end, { desc = "Pausar/retomar reprodução no YTNvim" })

vim.api.nvim_create_user_command("YTFullscreen", function()
  yt.toggle_fullscreen()
end, { desc = "Alternar tela cheia do vídeo no YTNvim" })
