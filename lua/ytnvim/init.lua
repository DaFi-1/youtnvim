local config = require("ytnvim.config")
local ui = require("ytnvim.ui")
local player = require("ytnvim.player")

local M = {}

M.setup = function(opts)
  config.setup(opts)
  if config.opts.keymap and type(config.opts.keymap) == "string" and config.opts.keymap ~= "" then
    vim.keymap.set("n", config.opts.keymap, ui.toggle, { silent = true, desc = "Alternar YTNvim (YouTube)" })
  end
end

M.open = ui.open
M.close = ui.close
M.toggle = ui.toggle
M.search = ui.do_search
M.prompt_search = ui.prompt_search
M.is_open = ui.is_open

M.play = player.play
M.stop = player.stop
M.toggle_pause = player.toggle_pause
M.toggle_fullscreen = player.toggle_fullscreen
M.toggle_ontop = player.toggle_ontop
M.load_channel = ui.load_channel

return M
