local config = require("ytnvim.config")

local M = {}

local active_download = nil
local last_drawn_id = nil
local IMAGE_ID = 99201

local function is_in_tmux()
  return vim.env.TMUX ~= nil or (vim.env.TERM_PROGRAM == "tmux")
end

local function wrap_tmux(seq)
  if is_in_tmux() then
    return "\027Ptmux;" .. seq:gsub("\027", "\027\027") .. "\027\\"
  end
  return seq
end

local function send_terminal_seq(seq)
  if vim.v.stderr then
    local ok = pcall(vim.api.nvim_chan_send, vim.v.stderr, seq)
    if ok then
      return
    end
  end
  pcall(function()
    io.stdout:write(seq)
    io.stdout:flush()
  end)
end

local RES_MAP = {
  maxresdefault = "maxresdefault",
  sddefault = "sddefault",
  hqdefault = "hqdefault",
  mqdefault = "mqdefault",
  default = "default",
  ["1080p"] = "maxresdefault",
  ["720p"] = "maxresdefault",
  hd = "maxresdefault",
  ["480p"] = "sddefault",
  ["360p"] = "mqdefault",
  high = "hqdefault",
  med = "mqdefault",
  low = "default",
  ["120p"] = "default",
}

local cached_cache_dir = nil
local function get_cache_dir()
  if cached_cache_dir then
    return cached_cache_dir
  end
  local dir = (config.opts.data_dir or (vim.fn.stdpath("data") .. "/ytnvim")) .. "/thumbnails"
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  cached_cache_dir = dir
  return dir
end

local cached_res = nil
local function get_thumb_res()
  if cached_res then
    return cached_res
  end
  local val = config.opts.thumb_quality
    or config.opts.thumb_resolution
    or config.opts.thumbnail_quality
    or config.opts.thumbnail_resolution
    or "hqdefault"

  local clean_val = string.lower(tostring(val)):gsub("%s+", "")
  cached_res = RES_MAP[clean_val] or clean_val
  return cached_res
end

local png_cache = {}
local png_cache_count = 0
local MAX_PNG_CACHE = 256

function M.get_png_path(video_id)
  if not video_id or video_id == "" then
    return nil
  end
  local cached = png_cache[video_id]
  if cached then
    return cached
  end
  local clean_id = video_id:gsub("[^%w%-_]", "")
  local res = get_thumb_res()
  local path = get_cache_dir() .. "/" .. clean_id .. "_" .. res .. ".png"
  if png_cache_count >= MAX_PNG_CACHE then
    png_cache = {}
    png_cache_count = 0
  end
  png_cache[video_id] = path
  png_cache_count = png_cache_count + 1
  return path
end

local tmux_offset_left = 0
local tmux_offset_top = 0
local last_tmux_query = 0
local last_editor_cols = -1
local last_editor_lines = -1

function M.invalidate_tmux_offset()
  last_tmux_query = 0
  last_editor_cols = -1
  last_editor_lines = -1
  cached_res = nil
  cached_cache_dir = nil
  png_cache = {}
  png_cache_count = 0
end

local function get_tmux_pane_offset()
  if not is_in_tmux() then
    return 0, 0
  end
  local cols = vim.o.columns
  local lines = vim.o.lines
  if cols == last_editor_cols and lines == last_editor_lines and last_tmux_query > 0 then
    return tmux_offset_left, tmux_offset_top
  end
  last_editor_cols = cols
  last_editor_lines = lines
  last_tmux_query = 1

  local args = { "tmux", "display-message", "-p" }
  if vim.env.TMUX_PANE and vim.env.TMUX_PANE ~= "" then
    args[#args + 1] = "-t"
    args[#args + 1] = vim.env.TMUX_PANE
  end
  args[#args + 1] = "#{pane_left},#{pane_top}"

  local ok, out = pcall(vim.fn.systemlist, args)
  if ok and out and out[1] then
    local x, y = out[1]:match("(%d+),(%d+)")
    if x and y then
      tmux_offset_left = tonumber(x) or 0
      tmux_offset_top = tonumber(y) or 0
    end
  end
  return tmux_offset_left, tmux_offset_top
end

function M.clear_image()
  local del_seq = string.format("\0277\027_Ga=d,d=i,i=%d,q=2\027\\\0278", IMAGE_ID)
  send_terminal_seq(wrap_tmux(del_seq))
  last_drawn_id = nil
end

function M.draw_image(png_path, win, start_row, start_col, cols, rows)
  if not png_path or vim.fn.filereadable(png_path) == 0 then
    return
  end
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  local win_pos = vim.api.nvim_win_get_position(win)
  local tmux_x, tmux_y = get_tmux_pane_offset()
  local target_row = win_pos[1] + (start_row or 1) + tmux_y
  local target_col = win_pos[2] + (start_col or 1) + tmux_x

  local b64 = vim.base64.encode(png_path)

  local raw_seq = string.format(
    "\0277\027_Ga=d,d=i,i=%d,q=2\027\\\027[%d;%dH\027_Ga=T,f=100,t=f,c=%d,r=%d,i=%d,C=1,q=2;%s\027\\\0278",
    IMAGE_ID,
    target_row,
    target_col,
    cols,
    rows,
    IMAGE_ID,
    b64
  )

  send_terminal_seq(wrap_tmux(raw_seq))
end

function M.invalidate_drawn()
  last_drawn_id = nil
end

function M.fetch_and_render(video, win, start_row, start_col, cols, rows, force, cb)
  if type(force) == "function" then
    cb = force
    force = false
  end

  if not video or not video.id or video.id == "" then
    M.clear_image()
    if cb then cb(false) end
    return
  end

  local png_path = M.get_png_path(video.id)
  if vim.fn.filereadable(png_path) == 1 then
    if not force and last_drawn_id == video.id then
      if cb then cb(true, png_path) end
      return
    end
    last_drawn_id = video.id
    M.draw_image(png_path, win, start_row, start_col, cols, rows)
    if cb then cb(true, png_path) end
    return
  end

  if active_download then
    pcall(function() active_download:kill(9) end)
    active_download = nil
  end

  local res = get_thumb_res()
  local video_id = video.id
  local jpg_path = get_cache_dir() .. "/" .. video_id .. "_" .. res .. ".jpg"

  local primary_url = "https://i.ytimg.com/vi/" .. video_id .. "/" .. res .. ".jpg"
  local fallback_hq = "https://i.ytimg.com/vi/" .. video_id .. "/hqdefault.jpg"
  local fallback_mq = "https://i.ytimg.com/vi/" .. video_id .. "/mqdefault.jpg"

  local cmd = string.format(
    "(curl -sL --max-time 6 -f %s -o %s || curl -sL --max-time 6 -f %s -o %s || curl -sL --max-time 6 %s -o %s) && ffmpeg -y -v error -i %s %s && rm -f %s",
    vim.fn.shellescape(primary_url),
    vim.fn.shellescape(jpg_path),
    vim.fn.shellescape(fallback_hq),
    vim.fn.shellescape(jpg_path),
    vim.fn.shellescape(fallback_mq),
    vim.fn.shellescape(jpg_path),
    vim.fn.shellescape(jpg_path),
    vim.fn.shellescape(png_path),
    vim.fn.shellescape(jpg_path)
  )

  active_download = vim.system({ "sh", "-c", cmd }, {}, function(obj)
    active_download = nil
    vim.schedule(function()
      if obj.code == 0 and vim.fn.filereadable(png_path) == 1 then
        if win and vim.api.nvim_win_is_valid(win) then
          last_drawn_id = video_id
          M.draw_image(png_path, win, start_row, start_col, cols, rows)
          if cb then cb(true, png_path) end
        end
      else
        if cb then cb(false) end
      end
    end)
  end)
end

return M
