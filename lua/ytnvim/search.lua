local config = require("ytnvim.config")

local M = {}

local active_job = nil

local function format_views(views_str)
  local n = tonumber(views_str)
  if not n then
    return (views_str and views_str ~= "NA" and views_str ~= "") and views_str or "-"
  end
  if n >= 1e9 then
    return string.format("%.1fB", n / 1e9)
  elseif n >= 1e6 then
    return string.format("%.1fM", n / 1e6)
  elseif n >= 1e3 then
    return string.format("%.1fK", n / 1e3)
  else
    return tostring(n)
  end
end

local function parse_ytdl_tab_output(stdout)
  local items = {}
  if not stdout or stdout == "" then
    return items
  end

  for line in stdout:gmatch("[^\r\n]+") do
    local p1, p2, p3, p4, p5, p6 = line:match("^(.-)\t(.-)\t(.-)\t(.-)\t(.-)\t(.*)$")
    if p1 and p2 then
      local id = vim.trim(p1)
      if id ~= "" then
        local title = vim.trim(p2 ~= "" and p2 or "Sem título")
        local duration = vim.trim(p3)
        if duration == "NA" or duration == "" then
          duration = "Ao Vivo"
        end
        local uploader = vim.trim(p4 ~= "" and p4 or "Desconhecido")
        local raw_views = vim.trim(p5)
        local thumb_url = vim.trim(p6)
        if thumb_url == "" or thumb_url == "NA" then
          thumb_url = "https://i.ytimg.com/vi/" .. id .. "/mqdefault.jpg"
        end

        items[#items + 1] = {
          id = id,
          title = title,
          duration = duration,
          uploader = uploader,
          views = format_views(raw_views),
          thumbnail_url = thumb_url,
          url = "https://www.youtube.com/watch?v=" .. id,
        }
      end
    end
  end

  return items
end

function M.search(query, cb)
  if not query or vim.trim(query) == "" then
    if cb then cb({}) end
    return
  end

  query = vim.trim(query)
  M.cancel()

  local limit = config.opts.search_limit or 20
  local search_term = string.format("ytsearch%d:%s", limit, query)
  local print_format = "%(id)s\t%(title)s\t%(duration_string)s\t%(uploader)s\t%(view_count)s\t%(thumbnails.-1.url)s"

  local args = {
    "yt-dlp",
    "--flat-playlist",
    "--print",
    print_format,
    search_term,
  }

  active_job = vim.system(args, { text = true }, function(obj)
    active_job = nil
    local items = parse_ytdl_tab_output(obj.stdout)
    vim.schedule(function()
      if cb then
        cb(items, obj.code == 0)
      end
    end)
  end)
end

function M.fetch_channel(channel_url, cb)
  if not channel_url or vim.trim(channel_url) == "" then
    if cb then cb({}) end
    return
  end

  channel_url = vim.trim(channel_url)
  if not channel_url:find("/videos") and not channel_url:find("/streams") and not channel_url:find("/shorts") then
    channel_url = channel_url:gsub("/+$", "") .. "/videos"
  end

  M.cancel()

  local limit = config.opts.search_limit or 20
  local print_format = "%(id)s\t%(title)s\t%(duration_string)s\t%(uploader)s\t%(view_count)s\t%(thumbnails.-1.url)s"

  local args = {
    "yt-dlp",
    "--flat-playlist",
    "--print",
    print_format,
    "--playlist-end",
    tostring(limit),
    channel_url,
  }

  active_job = vim.system(args, { text = true }, function(obj)
    active_job = nil
    local items = parse_ytdl_tab_output(obj.stdout)
    vim.schedule(function()
      if cb then
        cb(items, obj.code == 0)
      end
    end)
  end)
end

function M.cancel()
  if active_job then
    pcall(function()
      active_job:kill(9)
    end)
    active_job = nil
  end
end

return M
