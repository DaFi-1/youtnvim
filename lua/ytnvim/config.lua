local M = {}

M.defaults = {
  keymap = "<space>a",
  volume = 30, -- Volume inicial (0 a 100)
  quality = "1080p", -- Qualidade do vídeo: "1080p", "720p", "480p", "360p", "best"
  thumb_quality = "hqdefault", -- Resolução da thumbnail: "maxresdefault" (HD), "sddefault", "hqdefault" (Alta), "mqdefault" (Média), "default" (Baixa)
  search_limit = 20,
  width = 124, -- Largura fixa da janela em colunas (ou <= 1 para porcentagem)
  height = 26, -- Altura fixa da janela em linhas (ou <= 1 para porcentagem)
  thumb_width = 38,
  channel_width = 24,
  border = "rounded",
  player_cmd = "mpv",
  video = true, -- Reproduzir vídeo na janela do mpv por padrão
  mpv_video_args = {
    "--force-window=yes",
    "--autofit=55%x55%",
    "--geometry=96%:4%",
    "--ontop",
  },
  mpv_audio_args = {
    "--no-video",
    "--ytdl-format=bestaudio/best",
  },
  cookies = "auto",
  data_dir = vim.fn.stdpath("data") .. "/ytnvim",
  channels = {
    { name = "Lofi Girl", url = "https://www.youtube.com/@LofiGirl" },
    { name = "NoCopyrightSounds", url = "https://www.youtube.com/@NoCopyrightSounds" },
    { name = "ChilledCow", url = "https://www.youtube.com/@ChilledCow" },
    { name = "Chillhop Music", url = "https://www.youtube.com/@ChillhopMusic" },
  },
}

M.opts = {}

function M.setup(opts)
  opts = opts or {}
  M.opts = vim.tbl_deep_extend("force", M.defaults, opts)

  -- Normaliza lista de canais com preenchimento eficiente e mapa de busca O(1)
  local norm_channels = {}
  local channel_map = {}
  for _, ch in ipairs(M.opts.channels or {}) do
    local item = nil
    if type(ch) == "string" then
      local name = ch:match("@([%w%-_]+)") or ch
      item = { name = name, url = ch }
    elseif type(ch) == "table" and ch.url then
      item = {
        name = ch.name or ch.url:match("@([%w%-_]+)") or "Canal",
        url = ch.url,
      }
    end
    if item then
      norm_channels[#norm_channels + 1] = item
      channel_map[item.url] = item
    end
  end
  M.opts.channels = norm_channels
  M.channel_map = channel_map

  local thumb_dir = M.opts.data_dir .. "/thumbnails"
  if vim.fn.isdirectory(thumb_dir) == 0 then
    vim.fn.mkdir(thumb_dir, "p")
  end
end

M.setup()

return M
