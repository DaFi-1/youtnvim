local config = require("ytnvim.config")
local search = require("ytnvim.search")
local preview = require("ytnvim.preview")
local player = require("ytnvim.player")
local uv = vim.uv or vim.loop

local M = {}

local thumb_win = nil
local thumb_buf = nil
local list_win = nil
local list_buf = nil
local channel_win = nil
local channel_buf = nil

local search_results = {}
local channels_list = {}
local active_channel = nil
local current_query = ""
local current_source_type = "search" -- "search" or "channel"
local is_searching = false
local is_editing_search = false
local ui_anim_timer = nil
local thumb_debounce_timer = nil

local ns_id = vim.api.nvim_create_namespace("ytnvim_ui")
local thumb_ns_id = vim.api.nvim_create_namespace("ytnvim_thumb")
local channel_ns_id = vim.api.nvim_create_namespace("ytnvim_channel")

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function get_spinner_frame()
  local t = math.floor(uv.hrtime() / 1e8)
  local idx = (t % #SPINNER_FRAMES) + 1
  return SPINNER_FRAMES[idx]
end

local hl_initialized = false
local function setup_highlights()
  if hl_initialized then
    return
  end
  hl_initialized = true

  local set_hl = vim.api.nvim_set_hl
  set_hl(0, "YTNvimNormal", { bg = "#000000", fg = "#ffffff", default = false })
  set_hl(0, "YTNvimBorder", { bg = "#000000", fg = "#ffffff", default = false })
  set_hl(0, "YTNvimBorderActive", { bg = "#000000", fg = "#ffffff", bold = true, default = false })
  set_hl(0, "YTNvimTitle", { bg = "#000000", fg = "#ffffff", bold = true, default = false })
  set_hl(0, "YTNvimPlaying", { bg = "#000000", fg = "#ffffff", bold = true, default = false })
  set_hl(0, "YTNvimPaused", { bg = "#000000", fg = "#888888", default = false })
  set_hl(0, "YTNvimBuffering", { bg = "#000000", fg = "#888888", default = false })
  set_hl(0, "YTNvimMuted", { bg = "#000000", fg = "#888888", default = false })
  set_hl(0, "YTNvimSelected", { bg = "#ffffff", fg = "#000000", bold = true, default = false })
  set_hl(0, "YTNvimCursorLine", { bg = "#ffffff", fg = "#000000", bold = true, default = false })
  set_hl(0, "YTNvimHeader", { bg = "#000000", fg = "#ffffff", bold = true, default = false })
  set_hl(0, "YTNvimChannel", { bg = "#000000", fg = "#888888", default = false })
  set_hl(0, "YTNvimChannelActive", { bg = "#000000", fg = "#ffffff", bold = true, default = false })
  set_hl(0, "YTNvimDuration", { bg = "#000000", fg = "#888888", default = false })
  set_hl(0, "YTNvimDate", { bg = "#000000", fg = "#888888", default = false })
end

function M.is_open()
  return list_win ~= nil and vim.api.nvim_win_is_valid(list_win)
end

local strwidth = vim.api.nvim_strwidth
local str_byte = string.byte
local str_sub = string.sub

local function fast_truncate(text, max_len)
  if not text or text == "" then
    return ""
  end
  if strwidth(text) <= max_len then
    return text
  end

  local cur_w = 0
  local last_safe_byte = 0
  local len = #text
  local i = 1

  while i <= len do
    local b = str_byte(text, i)
    local char_len = 1
    local char_w = 1

    if b < 0x80 then
      char_len = 1
      char_w = 1
    elseif b >= 0xC0 and b < 0xE0 then
      char_len = 2
      char_w = strwidth(str_sub(text, i, i + 1))
    elseif b >= 0xE0 and b < 0xF0 then
      char_len = 3
      char_w = strwidth(str_sub(text, i, i + 2))
    elseif b >= 0xF0 then
      char_len = 4
      char_w = strwidth(str_sub(text, i, i + 3))
    end

    if cur_w + char_w + 1 > max_len then
      break
    end

    cur_w = cur_w + char_w
    i = i + char_len
    last_safe_byte = i - 1
  end

  if last_safe_byte == 0 then
    return "…"
  end
  return str_sub(text, 1, last_safe_byte) .. "…"
end

local function resolve_dimension(val, total, default_fixed)
  local num = tonumber(val)
  if not num or num <= 0 then
    num = default_fixed
  end
  if num <= 1 then
    return math.floor(total * num)
  else
    return math.floor(num)
  end
end

local cached_geom = nil
local function calc_geometry()
  if cached_geom then
    return cached_geom
  end

  local total_w = vim.o.columns
  local total_h = vim.o.lines

  local target_w = resolve_dimension(config.opts.width, total_w, 124)
  local modal_w = math.min(total_w - 2, math.max(68, target_w))

  local target_h = resolve_dimension(config.opts.height, total_h, 26)
  local modal_h = math.min(total_h - 2, math.max(16, target_h))

  local thumb_w = math.min(42, math.max(34, config.opts.thumb_width or 38))
  local channel_w = math.min(28, math.max(20, config.opts.channel_width or 24))
  local list_w = math.max(20, modal_w - thumb_w - channel_w - 6)

  local outer_w = thumb_w + list_w + channel_w + 6
  local outer_h = modal_h + 2

  local start_col = math.max(0, math.floor((total_w - outer_w) / 2))
  local start_row = math.max(0, math.floor((total_h - outer_h) / 2))

  cached_geom = {
    thumb_w = thumb_w,
    list_w = list_w,
    channel_w = channel_w,
    height = modal_h,
    start_row = start_row,
    thumb_col = start_col,
    list_col = start_col + thumb_w + 2,
    channel_col = start_col + thumb_w + list_w + 4,
  }
  return cached_geom
end

local function fast_wrap_text(text, width)
  if not text or text == "" then
    return {}
  end
  local lines = {}
  local cur_line = ""
  local cur_w = 0

  for w in text:gmatch("%S+") do
    local w_len = strwidth(w)
    if cur_line == "" then
      cur_line = w
      cur_w = w_len
    else
      if cur_w + 1 + w_len <= width then
        cur_line = cur_line .. " " .. w
        cur_w = cur_w + 1 + w_len
      else
        lines[#lines + 1] = cur_line
        cur_line = w
        cur_w = w_len
      end
    end
  end

  if cur_line ~= "" then
    lines[#lines + 1] = cur_line
  end
  return lines
end

local render_thumbnail_pane
local fetch_publish_date
local date_cache = {}
local active_date_job = nil

fetch_publish_date = function(video)
  if not video or not video.id or video.publish_date or video._fetching_date then
    return
  end

  local cached_date = date_cache[video.id]
  if cached_date then
    video.publish_date = cached_date
    return
  end

  if active_date_job then
    pcall(function() active_date_job:kill(9) end)
    active_date_job = nil
  end

  video._fetching_date = true
  local url = "https://www.youtube.com/watch?v=" .. video.id
  active_date_job = vim.system({ "curl", "-sL", "--max-time", "4", url }, { text = true }, function(obj)
    active_date_job = nil
    local date_str = nil
    if obj.code == 0 and obj.stdout then
      local y, m, d = obj.stdout:match('"publishDate":"(%d%d%d%d)%-(%d%d)%-(%d%d)')
      if not y then
        y, m, d = obj.stdout:match('"uploadDate":"(%d%d%d%d)%-(%d%d)%-(%d%d)')
      end
      if y and m and d then
        date_str = string.format("%s/%s/%s", d, m, y)
      end
    end
    vim.schedule(function()
      local final_date = date_str or "-"
      video.publish_date = final_date
      date_cache[video.id] = final_date
      video._fetching_date = false
      if M.is_open() and list_win and vim.api.nvim_win_is_valid(list_win) then
        local cursor = vim.api.nvim_win_get_cursor(list_win)
        local cur_idx = cursor[1] - 2
        if cur_idx >= 1 and search_results[cur_idx] and search_results[cur_idx].id == video.id then
          render_thumbnail_pane(video)
        end
      end
    end)
  end)
end

local function set_buf_lines(buf, start_idx, end_idx, lines)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, start_idx, end_idx, false, lines)
  vim.bo[buf].modifiable = false
end

local thumb_active_opt = 1
local thumb_opt_cols = { 3, 9, 15, 18 }
local thumb_opt_ranges = {
  { 3, 7 },    -- 󰐊
  { 9, 13 },   -- 󰏤
  { 15, 16 },  -- +
  { 18, 19 },  -- -
}

local function render_thumb_controls()
  if not thumb_buf or not vim.api.nvim_buf_is_valid(thumb_buf) then
    return
  end
  local geom = calc_geometry()
  local w = geom.thumb_w
  local h = geom.height
  local vol = player.get_volume and player.get_volume() or 30
  local ctrl_line = string.format("   󰐊  󰏤  +  -  (%d%%)", vol)
  local padded = ctrl_line .. string.rep(" ", math.max(0, w - strwidth(ctrl_line)))

  set_buf_lines(thumb_buf, h - 1, h, { padded })

  local row_idx = h - 1
  vim.api.nvim_buf_clear_namespace(thumb_buf, thumb_ns_id, row_idx, row_idx + 1)

  local is_focused = (thumb_win and vim.api.nvim_win_is_valid(thumb_win) and vim.api.nvim_get_current_win() == thumb_win)

  if is_focused and thumb_active_opt == 1 then
    vim.api.nvim_buf_add_highlight(thumb_buf, thumb_ns_id, "YTNvimSelected", row_idx, 3, 7)
  else
    vim.api.nvim_buf_add_highlight(thumb_buf, thumb_ns_id, "YTNvimPlaying", row_idx, 3, 7)
  end

  if is_focused and thumb_active_opt == 2 then
    vim.api.nvim_buf_add_highlight(thumb_buf, thumb_ns_id, "YTNvimSelected", row_idx, 9, 13)
  else
    vim.api.nvim_buf_add_highlight(thumb_buf, thumb_ns_id, "YTNvimPaused", row_idx, 9, 13)
  end

  if is_focused and thumb_active_opt == 3 then
    vim.api.nvim_buf_add_highlight(thumb_buf, thumb_ns_id, "YTNvimSelected", row_idx, 15, 16)
  else
    vim.api.nvim_buf_add_highlight(thumb_buf, thumb_ns_id, "YTNvimNormal", row_idx, 15, 16)
  end

  if is_focused and thumb_active_opt == 4 then
    vim.api.nvim_buf_add_highlight(thumb_buf, thumb_ns_id, "YTNvimSelected", row_idx, 18, 19)
  else
    vim.api.nvim_buf_add_highlight(thumb_buf, thumb_ns_id, "YTNvimNormal", row_idx, 18, 19)
  end

  vim.api.nvim_buf_add_highlight(thumb_buf, thumb_ns_id, "YTNvimChannel", row_idx, 21, -1)
end

local current_thumb_video = nil

local function refresh_thumbnail(force)
  if not M.is_open() then
    return
  end
  local vid = current_thumb_video or player.get_current_video()
  if not vid and list_win and vim.api.nvim_win_is_valid(list_win) and #search_results > 0 then
    local cursor = vim.api.nvim_win_get_cursor(list_win)
    local idx = cursor[1] - 2
    if idx >= 1 and search_results[idx] then
      vid = search_results[idx]
    end
  end
  if vid then
    preview.invalidate_drawn()
    render_thumbnail_pane(vid, force or true)
  end
end

render_thumbnail_pane = function(video, force)
  if not thumb_buf or not vim.api.nvim_buf_is_valid(thumb_buf) then
    return
  end
  if video ~= nil then
    current_thumb_video = video
  end
  local geom = calc_geometry()
  local w = geom.thumb_w
  local h = geom.height

  local lines = {}
  local blank_line = string.rep(" ", w)
  lines[1] = blank_line

  local left_offset = 4
  local img_w = math.max(10, w - left_offset - 1)
  local img_h = math.min(9, math.max(6, math.floor(img_w / 3.2)))
  local top_offset = 2

  for _ = 1, img_h do
    lines[#lines + 1] = blank_line
  end
  lines[#lines + 1] = string.rep("─", w)

  local title_start_idx = #lines

  if video then
    local max_title_lines = (h < 22) and 2 or 3
    local title_lines = fast_wrap_text(video.title or "Sem título", w - 5)
    for i = 1, math.min(max_title_lines, #title_lines) do
      local tl = "   " .. title_lines[i]
      lines[#lines + 1] = tl .. string.rep(" ", math.max(0, w - strwidth(tl)))
    end

    lines[#lines + 1] = blank_line
    local ch = "   󰜈 Canal: " .. fast_truncate(video.uploader or "-", w - 13)
    lines[#lines + 1] = ch .. string.rep(" ", math.max(0, w - strwidth(ch)))

    local dur = "   󱎫 Duração: " .. (video.duration or "-")
    lines[#lines + 1] = dur .. string.rep(" ", math.max(0, w - strwidth(dur)))

    local views = "   󰍹 Visualizações: " .. (video.views or "-")
    lines[#lines + 1] = views .. string.rep(" ", math.max(0, w - strwidth(views)))

    local pub_val = video.publish_date or (date_cache[video.id] or "Carregando...")
    local pub = "    Publicado: " .. pub_val
    lines[#lines + 1] = pub .. string.rep(" ", math.max(0, w - strwidth(pub)))

    if not video.publish_date and not date_cache[video.id] then
      fetch_publish_date(video)
    end

    local cur_playing = player.get_current_video()
    if cur_playing and cur_playing.id == video.id then
      lines[#lines + 1] = blank_line
      local p_status = player.get_status()
      local play_label
      if p_status == "buffering" then
        play_label = "   " .. get_spinner_frame() .. " Carregando vídeo..."
      elseif p_status == "paused" then
        play_label = "   󰏤 Pausado"
      else
        play_label = "   󰐊 Tocando agora..."
      end
      lines[#lines + 1] = play_label .. string.rep(" ", math.max(0, w - strwidth(play_label)))
    end
  else
    lines[#lines + 1] = blank_line
  end

  while #lines < h - 2 do
    lines[#lines + 1] = blank_line
  end

  local ctrl_sep = string.rep("─", w)
  lines[h - 1] = ctrl_sep
  local vol = player.get_volume and player.get_volume() or 30
  local ctrl_line = string.format("   󰐊  󰏤  +  -  (%d%%)", vol)
  lines[h] = ctrl_line .. string.rep(" ", math.max(0, w - strwidth(ctrl_line)))

  set_buf_lines(thumb_buf, 0, -1, lines)

  vim.api.nvim_buf_clear_namespace(thumb_buf, thumb_ns_id, 0, -1)
  vim.api.nvim_buf_add_highlight(thumb_buf, thumb_ns_id, "YTNvimBorder", img_h + 1, 0, -1)
  if video then
    vim.api.nvim_buf_add_highlight(thumb_buf, thumb_ns_id, "YTNvimTitle", title_start_idx, 0, -1)
  end
  vim.api.nvim_buf_add_highlight(thumb_buf, thumb_ns_id, "YTNvimBorder", h - 2, 0, -1)

  render_thumb_controls()

  if video and thumb_win and vim.api.nvim_win_is_valid(thumb_win) then
    preview.fetch_and_render(video, thumb_win, top_offset, left_offset, img_w, img_h, force)
  else
    preview.clear_image()
  end
end

local function render_list_pane()
  if not list_buf or not vim.api.nvim_buf_is_valid(list_buf) then
    return
  end
  if is_editing_search then
    return
  end
  local geom = calc_geometry()
  local w = geom.list_w

  local lines = {}
  local cur_video = player.get_current_video()
  local play_status = player.get_status()

  -- Header line (barra de busca)
  local search_header
  if is_searching then
    local label = current_query ~= "" and fast_truncate(current_query, 20) or ""
    if label ~= "" then
      search_header = string.format("  %s %s", get_spinner_frame(), label)
    else
      search_header = string.format("  %s", get_spinner_frame())
    end
  elseif current_query ~= "" then
    search_header = string.format("   %s", fast_truncate(current_query, math.max(10, w - 6)))
  else
    search_header = "   "
  end

  local header_pad = math.max(0, w - strwidth(search_header))
  lines[1] = header_pad > 0 and (search_header .. string.rep(" ", header_pad)) or search_header
  lines[2] = string.rep("─", w)

  -- Results list
  local num_results = #search_results
  if num_results == 0 then
    if is_searching then
      lines[3] = "    " .. get_spinner_frame()
    end
  else
    local avail_title_w = math.max(10, w - 8)
    for i = 1, num_results do
      local item = search_results[i]
      local is_cur = (cur_video and cur_video.id == item.id and play_status ~= "stopped")
      local prefix
      if is_cur then
        local p_icon = (play_status == "buffering" and get_spinner_frame())
          or (play_status == "paused" and "󰏤")
          or "󰐊"
        prefix = string.format(" %s %02d. ", p_icon, i)
      else
        prefix = string.format("   %02d. ", i)
      end

      local title_str = item._cached_title
      if not title_str or item._cached_w ~= avail_title_w then
        title_str = fast_truncate(item.title, avail_title_w)
        item._cached_title = title_str
        item._cached_w = avail_title_w
      end
      lines[#lines + 1] = prefix .. title_str
    end
  end

  set_buf_lines(list_buf, 0, -1, lines)

  -- Highlights
  vim.api.nvim_buf_clear_namespace(list_buf, ns_id, 0, -1)
  vim.api.nvim_buf_add_highlight(list_buf, ns_id, "YTNvimTitle", 0, 0, -1)
  -- Linha divisória branca como as outras
  vim.api.nvim_buf_add_highlight(list_buf, ns_id, "YTNvimBorder", 1, 0, -1)

  if cur_video and play_status ~= "stopped" then
    for i = 1, num_results do
      if search_results[i].id == cur_video.id then
        vim.api.nvim_buf_add_highlight(list_buf, ns_id, "YTNvimTitle", i + 1, 0, 4)
        break
      end
    end
  end
end

local function render_channel_pane()
  if not channel_buf or not vim.api.nvim_buf_is_valid(channel_buf) then
    return
  end
  local geom = calc_geometry()
  local w = geom.channel_w
  local h = geom.height

  local lines = {}
  local num_channels = #channels_list
  if num_channels == 0 then
    lines[1] = "   (nenhum canal)"
    lines[2] = "   Pressione 'a' para add"
  else
    for i = 1, num_channels do
      local ch = channels_list[i]
      local is_active = (active_channel and active_channel.url == ch.url)
      local prefix = is_active and " 󰐊 " or "   "
      local label = prefix .. fast_truncate(ch.name, w - 6)
      local pad = math.max(0, w - strwidth(label))
      lines[i] = pad > 0 and (label .. string.rep(" ", pad)) or label
    end
  end

  local blank_line = string.rep(" ", w)
  for i = #lines + 1, h do
    lines[i] = blank_line
  end

  set_buf_lines(channel_buf, 0, -1, lines)

  vim.api.nvim_buf_clear_namespace(channel_buf, channel_ns_id, 0, -1)
  for i = 1, num_channels do
    local l_idx = i - 1
    local is_active = (active_channel and active_channel.url == channels_list[i].url)
    if is_active then
      vim.api.nvim_buf_add_highlight(channel_buf, channel_ns_id, "YTNvimTitle", l_idx, 0, 4)
    end
  end
end

local pending_thumb_video = nil
local on_thumb_debounce_tick = vim.schedule_wrap(function()
  if M.is_open() and pending_thumb_video then
    render_thumbnail_pane(pending_thumb_video)
  end
end)

local is_moving_cursor = false
local function on_list_cursor_moved()
  if is_moving_cursor then
    return
  end
  if not list_win or not vim.api.nvim_win_is_valid(list_win) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(list_win)
  local row = cursor[1]

  if is_editing_search then
    vim.wo[list_win].cursorline = false
    return
  end

  if row == 1 then
    vim.wo[list_win].cursorline = true
    return
  end

  if row == 2 then
    is_moving_cursor = true
    if #search_results > 0 then
      vim.api.nvim_win_set_cursor(list_win, { 3, 0 })
      row = 3
    else
      vim.api.nvim_win_set_cursor(list_win, { 1, 0 })
      vim.wo[list_win].cursorline = true
      is_moving_cursor = false
      return
    end
    is_moving_cursor = false
  end

  vim.wo[list_win].cursorline = true

  local item_idx = row - 2
  if item_idx < 1 or item_idx > #search_results then
    return
  end

  local video = search_results[item_idx]
  if not video then
    return
  end

  pending_thumb_video = video
  if not thumb_debounce_timer then
    thumb_debounce_timer = uv.new_timer()
  end
  thumb_debounce_timer:stop()
  thumb_debounce_timer:start(50, 0, on_thumb_debounce_tick)
end

local function update_anim_timer()
  local needs_anim = is_searching or (player.get_status() == "buffering")
  if needs_anim then
    if not ui_anim_timer then
      ui_anim_timer = uv.new_timer()
      ui_anim_timer:start(80, 80, vim.schedule_wrap(function()
        if not M.is_open() then
          if ui_anim_timer and not ui_anim_timer:is_closing() then
            ui_anim_timer:stop()
            ui_anim_timer:close()
          end
          ui_anim_timer = nil
          return
        end

        local still_needs = is_searching or (player.get_status() == "buffering")
        if still_needs then
          render_list_pane()
        else
          if ui_anim_timer and not ui_anim_timer:is_closing() then
            ui_anim_timer:stop()
            ui_anim_timer:close()
          end
          ui_anim_timer = nil
          render_list_pane()
        end
      end))
    end
  else
    if ui_anim_timer and not ui_anim_timer:is_closing() then
      ui_anim_timer:stop()
      ui_anim_timer:close()
    end
    ui_anim_timer = nil
  end
end

function M.load_channel(channel)
  if not channel or not channel.url then
    return
  end
  active_channel = channel
  current_source_type = "channel"
  is_searching = true
  search_results = {}

  update_anim_timer()

  render_channel_pane()
  render_list_pane()
  render_thumbnail_pane(nil)

  search.fetch_channel(channel.url, function(items, ok)
    is_searching = false
    update_anim_timer()

    if ok and items then
      search_results = items
    else
      search_results = {}
      vim.notify(string.format("󰗃 YTNvim: Falha ao carregar vídeos do canal \"%s\"", channel.name), vim.log.levels.WARN)
    end

    if M.is_open() then
      render_channel_pane()
      render_list_pane()
      if list_win and vim.api.nvim_win_is_valid(list_win) then
        vim.api.nvim_set_current_win(list_win)
        if #search_results > 0 then
          vim.api.nvim_win_set_cursor(list_win, { 3, 0 })
          vim.wo[list_win].cursorline = true
          render_thumbnail_pane(search_results[1])
        else
          vim.api.nvim_win_set_cursor(list_win, { 1, 0 })
          vim.wo[list_win].cursorline = true
          render_thumbnail_pane(nil)
        end
      end
    end
  end)
end

function M.do_search(query)
  if not query or vim.trim(query) == "" then
    return
  end
  current_query = vim.trim(query)
  current_source_type = "search"
  active_channel = nil
  is_searching = true
  search_results = {}

  update_anim_timer()

  render_channel_pane()
  render_list_pane()
  render_thumbnail_pane(nil)
  if list_win and vim.api.nvim_win_is_valid(list_win) then
    vim.wo[list_win].cursorline = false
  end

  search.search(current_query, function(items, ok)
    is_searching = false
    update_anim_timer()

    if ok and items then
      search_results = items
    else
      search_results = {}
      vim.notify("󰗃 YTNvim: Falha ao buscar no YouTube", vim.log.levels.WARN)
    end

    if M.is_open() then
      render_channel_pane()
      render_list_pane()
      if list_win and vim.api.nvim_win_is_valid(list_win) then
        vim.api.nvim_set_current_win(list_win)
        if #search_results > 0 then
          vim.api.nvim_win_set_cursor(list_win, { 3, 0 })
          vim.wo[list_win].cursorline = true
          render_thumbnail_pane(search_results[1])
        else
          vim.api.nvim_win_set_cursor(list_win, { 1, 0 })
          vim.wo[list_win].cursorline = true
          render_thumbnail_pane(nil)
        end
      end
    end
  end)
end

function M.prompt_search(clear)
  if not list_win or not vim.api.nvim_win_is_valid(list_win) then
    return
  end
  if not list_buf or not vim.api.nvim_buf_is_valid(list_buf) then
    return
  end

  vim.api.nvim_set_current_win(list_win)

  local initial_query = (not clear and current_query) or ""
  local search_text = "   " .. initial_query

  set_buf_lines(list_buf, 0, 1, { search_text })
  vim.bo[list_buf].modifiable = true
  is_editing_search = true
  vim.wo[list_win].cursorline = false

  vim.api.nvim_win_set_cursor(list_win, { 1, #search_text })
  vim.cmd("startinsert!")
end

local function setup_all_keymaps()
  -- Helper to map in a specific buffer
  local function bmap(target_buf, key, fn)
    vim.keymap.set("n", key, fn, { buffer = target_buf, silent = true, nowait = true })
  end

  for _, b in ipairs({ thumb_buf, list_buf, channel_buf }) do
    bmap(b, "q", function()
      M.close()
    end)
    bmap(b, "<Esc>", function()
      M.close()
    end)
    -- Global Tab / S-Tab cycling between panes
    bmap(b, "<Tab>", function()
      local cur_w = vim.api.nvim_get_current_win()
      if cur_w == list_win then
        vim.api.nvim_set_current_win(channel_win)
        render_thumb_controls()
      elseif cur_w == channel_win then
        local geom = calc_geometry()
        vim.api.nvim_set_current_win(thumb_win)
        vim.api.nvim_win_set_cursor(thumb_win, { geom.height, thumb_opt_cols[thumb_active_opt] })
        render_thumb_controls()
      else
        vim.api.nvim_set_current_win(list_win)
        render_thumb_controls()
      end
    end)
    bmap(b, "<S-Tab>", function()
      local cur_w = vim.api.nvim_get_current_win()
      if cur_w == list_win then
        local geom = calc_geometry()
        vim.api.nvim_set_current_win(thumb_win)
        vim.api.nvim_win_set_cursor(thumb_win, { geom.height, thumb_opt_cols[thumb_active_opt] })
        render_thumb_controls()
      elseif cur_w == thumb_win then
        vim.api.nvim_set_current_win(channel_win)
        render_thumb_controls()
      else
        vim.api.nvim_set_current_win(list_win)
        render_thumb_controls()
      end
    end)
  end

  -- ==============================
  -- 1. Thumbnail Window Keymaps
  -- ==============================
  -- Controls navigation: 1: Play (󰐊), 2: Pause (󰏤), 3: Vol+ (+), 4: Vol- (-)
  local function move_thumb_opt(delta)
    local new_opt = thumb_active_opt + delta
    if new_opt >= 1 and new_opt <= 4 then
      thumb_active_opt = new_opt
      if thumb_win and vim.api.nvim_win_is_valid(thumb_win) then
        local geom = calc_geometry()
        vim.api.nvim_win_set_cursor(thumb_win, { geom.height, thumb_opt_cols[thumb_active_opt] })
        render_thumb_controls()
      end
    elseif new_opt > 4 then
      -- Moving right past the last option goes back to list window
      if list_win and vim.api.nvim_win_is_valid(list_win) then
        vim.api.nvim_set_current_win(list_win)
        render_thumb_controls()
      end
    end
  end

  bmap(thumb_buf, "l", function() move_thumb_opt(1) end)
  bmap(thumb_buf, "<Right>", function() move_thumb_opt(1) end)
  bmap(thumb_buf, "w", function() move_thumb_opt(1) end)
  bmap(thumb_buf, "h", function() move_thumb_opt(-1) end)
  bmap(thumb_buf, "<Left>", function() move_thumb_opt(-1) end)
  bmap(thumb_buf, "b", function() move_thumb_opt(-1) end)

  bmap(thumb_buf, "0", function()
    thumb_active_opt = 1
    if thumb_win and vim.api.nvim_win_is_valid(thumb_win) then
      local geom = calc_geometry()
      vim.api.nvim_win_set_cursor(thumb_win, { geom.height, thumb_opt_cols[1] })
      render_thumb_controls()
    end
  end)
  bmap(thumb_buf, "^", function()
    thumb_active_opt = 1
    if thumb_win and vim.api.nvim_win_is_valid(thumb_win) then
      local geom = calc_geometry()
      vim.api.nvim_win_set_cursor(thumb_win, { geom.height, thumb_opt_cols[1] })
      render_thumb_controls()
    end
  end)
  bmap(thumb_buf, "$", function()
    thumb_active_opt = 4
    if thumb_win and vim.api.nvim_win_is_valid(thumb_win) then
      local geom = calc_geometry()
      vim.api.nvim_win_set_cursor(thumb_win, { geom.height, thumb_opt_cols[4] })
      render_thumb_controls()
    end
  end)

  bmap(thumb_buf, "<Esc>", function()
    if list_win and vim.api.nvim_win_is_valid(list_win) then
      vim.api.nvim_set_current_win(list_win)
      render_thumb_controls()
    else
      M.close()
    end
  end)

  -- Lock cursor row to bottom options line on any up/down motion
  for _, k in ipairs({ "j", "k", "<Down>", "<Up>" }) do
    bmap(thumb_buf, k, function()
      if thumb_win and vim.api.nvim_win_is_valid(thumb_win) then
        local geom = calc_geometry()
        vim.api.nvim_win_set_cursor(thumb_win, { geom.height, thumb_opt_cols[thumb_active_opt] })
      end
    end)
  end

  -- Selection with <CR> on the options
  bmap(thumb_buf, "<CR>", function()
    local cur = player.get_current_video()
    if not cur and list_win and vim.api.nvim_win_is_valid(list_win) then
      local l_c = vim.api.nvim_win_get_cursor(list_win)
      local idx = l_c[1] - 2
      if idx >= 1 and search_results[idx] then
        cur = search_results[idx]
      end
    end

    if thumb_active_opt == 1 then
      -- Play
      if cur then
        if player.get_status() == "paused" then
          player.toggle_pause()
        else
          player.play(cur, true)
        end
        render_list_pane()
        render_thumbnail_pane(cur)
      end
    elseif thumb_active_opt == 2 then
      -- Pause
      player.toggle_pause()
      render_list_pane()
      if cur then
        render_thumbnail_pane(cur)
      end
    elseif thumb_active_opt == 3 then
      -- Volume +
      player.volume_up(5)
      render_thumb_controls()
    elseif thumb_active_opt == 4 then
      -- Volume -
      player.volume_down(5)
      render_thumb_controls()
    end

    if thumb_win and vim.api.nvim_win_is_valid(thumb_win) then
      local geom = calc_geometry()
      vim.api.nvim_win_set_cursor(thumb_win, { geom.height, thumb_opt_cols[thumb_active_opt] })
    end
  end)

  -- ==============================
  -- 2. Videos List Window Keymaps
  -- ==============================
  -- Window navigation (h = Thumbnail, l = Canais)
  bmap(list_buf, "h", function()
    if thumb_win and vim.api.nvim_win_is_valid(thumb_win) then
      local geom = calc_geometry()
      vim.api.nvim_set_current_win(thumb_win)
      vim.api.nvim_win_set_cursor(thumb_win, { geom.height, thumb_opt_cols[thumb_active_opt] })
      render_thumb_controls()
    end
  end)
  bmap(list_buf, "<Left>", function()
    if thumb_win and vim.api.nvim_win_is_valid(thumb_win) then
      local geom = calc_geometry()
      vim.api.nvim_set_current_win(thumb_win)
      vim.api.nvim_win_set_cursor(thumb_win, { geom.height, thumb_opt_cols[thumb_active_opt] })
      render_thumb_controls()
    end
  end)
  bmap(list_buf, "l", function()
    if channel_win and vim.api.nvim_win_is_valid(channel_win) then
      vim.api.nvim_set_current_win(channel_win)
    end
  end)
  bmap(list_buf, "<Right>", function()
    if channel_win and vim.api.nvim_win_is_valid(channel_win) then
      vim.api.nvim_set_current_win(channel_win)
    end
  end)

  -- Play Video (<CR> or v)
  bmap(list_buf, "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(list_win)
    if cursor[1] == 1 then
      M.prompt_search(false)
      return
    end
    if cursor[1] == 2 then
      return
    end
    local idx = cursor[1] - 2
    local item = search_results[idx]
    if item then
      player.play(item, true)
      update_anim_timer()
      render_list_pane()
      render_thumbnail_pane(item)
    end
  end)
  bmap(list_buf, "v", function()
    local cursor = vim.api.nvim_win_get_cursor(list_win)
    if cursor[1] == 1 then
      M.prompt_search(false)
      return
    end
    if cursor[1] == 2 then
      return
    end
    local idx = cursor[1] - 2
    local item = search_results[idx]
    if item then
      player.play(item, true)
      update_anim_timer()
      render_list_pane()
      render_thumbnail_pane(item)
    end
  end)

  -- Play Audio only (a)
  bmap(list_buf, "a", function()
    local cursor = vim.api.nvim_win_get_cursor(list_win)
    if cursor[1] == 1 then
      M.prompt_search(false)
      return
    end
    if cursor[1] == 2 then
      return
    end
    local idx = cursor[1] - 2
    local item = search_results[idx]
    if item then
      player.play(item, false)
      update_anim_timer()
      render_list_pane()
      render_thumbnail_pane(item)
    end
  end)

  -- Input on search bar (i, I, A)
  for _, k in ipairs({ "i", "I", "A" }) do
    bmap(list_buf, k, function()
      local cursor = vim.api.nvim_win_get_cursor(list_win)
      if cursor[1] == 1 then
        M.prompt_search(false)
      end
    end)
  end

  -- Clear and input on search bar (c, C, S, o, O)
  for _, k in ipairs({ "c", "C", "S", "o", "O" }) do
    bmap(list_buf, k, function()
      local cursor = vim.api.nvim_win_get_cursor(list_win)
      if cursor[1] == 1 then
        M.prompt_search(true)
      end
    end)
  end

  -- Fullscreen toggle (f)
  local function toggle_fullscreen_and_refresh()
    player.toggle_fullscreen()
    preview.invalidate_drawn()
    vim.defer_fn(function()
      refresh_thumbnail(true)
    end, 150)
    vim.defer_fn(function()
      refresh_thumbnail(true)
    end, 400)
  end

  bmap(list_buf, "f", toggle_fullscreen_and_refresh)
  bmap(thumb_buf, "f", toggle_fullscreen_and_refresh)
  bmap(channel_buf, "f", toggle_fullscreen_and_refresh)

  -- OnTop toggle (o)
  bmap(list_buf, "o", function()
    local cursor = vim.api.nvim_win_get_cursor(list_win)
    if cursor[1] == 1 then
      M.prompt_search(true)
      return
    end
    player.toggle_ontop()
  end)

  -- Toggle Pause (<Space>)
  bmap(list_buf, "<Space>", function()
    player.toggle_pause()
    render_list_pane()
  end)

  -- Stop (s / x)
  bmap(list_buf, "s", function()
    local cursor = vim.api.nvim_win_get_cursor(list_win)
    if cursor[1] == 1 then
      M.prompt_search(true)
      return
    end
    player.stop()
    render_list_pane()
  end)
  bmap(list_buf, "x", function()
    player.stop()
    render_list_pane()
  end)

  -- Volume (+ / -)
  bmap(list_buf, "+", function() player.volume_up(5); render_thumb_controls() end)
  bmap(list_buf, "=", function() player.volume_up(5); render_thumb_controls() end)
  bmap(list_buf, "-", function() player.volume_down(5); render_thumb_controls() end)
  bmap(list_buf, "_", function() player.volume_down(5); render_thumb_controls() end)

  -- Free Search (/)
  bmap(list_buf, "/", function()
    M.prompt_search(false)
  end)
  bmap(thumb_buf, "/", function()
    M.prompt_search(false)
  end)
  bmap(channel_buf, "/", function()
    M.prompt_search(false)
  end)

  -- ==============================
  -- Insert Mode Keymaps for list_buf (Inline Search)
  -- ==============================
  local function imap(key, fn, expr)
    vim.keymap.set("i", key, fn, { buffer = list_buf, silent = true, nowait = true, expr = expr or false })
  end

  local function submit_inline_search()
    if not is_editing_search then
      return
    end
    local line = vim.api.nvim_buf_get_lines(list_buf, 0, 1, false)[1] or ""
    local q = line:gsub("^%s*%s*", "")
    q = vim.trim(q)

    is_editing_search = false
    vim.cmd("stopinsert")
    vim.bo[list_buf].modifiable = false

    if q ~= "" then
      M.do_search(q)
    else
      render_list_pane()
      if list_win and vim.api.nvim_win_is_valid(list_win) then
        vim.api.nvim_win_set_cursor(list_win, { 1, 0 })
        vim.wo[list_win].cursorline = true
      end
    end
  end

  local function cancel_inline_search()
    if not is_editing_search then
      return
    end
    is_editing_search = false
    vim.cmd("stopinsert")
    vim.bo[list_buf].modifiable = false
    render_list_pane()
    if list_win and vim.api.nvim_win_is_valid(list_win) then
      vim.api.nvim_win_set_cursor(list_win, { 1, 0 })
      vim.wo[list_win].cursorline = true
    end
  end

  imap("<CR>", submit_inline_search)
  imap("<Esc>", cancel_inline_search)
  imap("<C-c>", cancel_inline_search)

  -- Protect search prefix from backspacing
  imap("<BS>", function()
    local c = vim.api.nvim_win_get_cursor(list_win)
    if c[1] == 1 and c[2] <= 6 then
      return ""
    end
    return "<BS>"
  end, true)

  imap("<C-h>", function()
    local c = vim.api.nvim_win_get_cursor(list_win)
    if c[1] == 1 and c[2] <= 6 then
      return ""
    end
    return "<C-h>"
  end, true)

  imap("<C-u>", function()
    local c = vim.api.nvim_win_get_cursor(list_win)
    if c[1] == 1 then
      set_buf_lines(list_buf, 0, 1, { "   " })
      vim.bo[list_buf].modifiable = true
      vim.api.nvim_win_set_cursor(list_win, { 1, 6 })
    end
  end)

  imap("<C-w>", function()
    local c = vim.api.nvim_win_get_cursor(list_win)
    if c[1] ~= 1 or c[2] <= 6 then
      return
    end
    local line = vim.api.nvim_buf_get_lines(list_buf, 0, 1, false)[1] or ""
    local before = line:sub(1, c[2])
    local after = line:sub(c[2] + 1)
    local prefix_part = before:sub(1, 6)
    local user_part = before:sub(7)
    local new_user_part = user_part:gsub("%s*[%w_%-]+%s*$", "")
    if new_user_part == user_part then
      new_user_part = user_part:gsub("%S+%s*$", "")
    end
    local new_line = prefix_part .. new_user_part .. after
    vim.api.nvim_buf_set_lines(list_buf, 0, 1, false, { new_line })
    vim.api.nvim_win_set_cursor(list_win, { 1, 6 + #new_user_part })
  end)

  imap("<Left>", function()
    local c = vim.api.nvim_win_get_cursor(list_win)
    if c[1] == 1 and c[2] <= 6 then
      return ""
    end
    return "<Left>"
  end, true)

  imap("<Home>", function()
    local c = vim.api.nvim_win_get_cursor(list_win)
    if c[1] == 1 then
      vim.api.nvim_win_set_cursor(list_win, { 1, 6 })
      return ""
    end
    return "<Home>"
  end, true)

  imap("<Down>", function()
    if not is_editing_search then
      return
    end
    is_editing_search = false
    vim.cmd("stopinsert")
    vim.bo[list_buf].modifiable = false
    render_list_pane()
    if #search_results > 0 then
      vim.api.nvim_win_set_cursor(list_win, { 3, 0 })
      vim.wo[list_win].cursorline = true
      local item = search_results[1]
      if item then
        render_thumbnail_pane(item)
      end
    else
      vim.api.nvim_win_set_cursor(list_win, { 1, 0 })
      vim.wo[list_win].cursorline = true
    end
  end)

  imap("<Up>", function()
    if not is_editing_search then
      return
    end
    cancel_inline_search()
  end)

  imap("<Tab>", function()
    if not is_editing_search then
      return
    end
    is_editing_search = false
    vim.cmd("stopinsert")
    vim.bo[list_buf].modifiable = false
    render_list_pane()
    if channel_win and vim.api.nvim_win_is_valid(channel_win) then
      vim.api.nvim_set_current_win(channel_win)
      render_thumb_controls()
    end
  end)

  imap("<S-Tab>", function()
    if not is_editing_search then
      return
    end
    is_editing_search = false
    vim.cmd("stopinsert")
    vim.bo[list_buf].modifiable = false
    render_list_pane()
    if thumb_win and vim.api.nvim_win_is_valid(thumb_win) then
      local geom = calc_geometry()
      vim.api.nvim_set_current_win(thumb_win)
      vim.api.nvim_win_set_cursor(thumb_win, { geom.height, thumb_opt_cols[thumb_active_opt] })
      render_thumb_controls()
    end
  end)

  -- Reload (r)
  bmap(list_buf, "r", function()
    if current_source_type == "channel" and active_channel then
      M.load_channel(active_channel)
    elseif current_query ~= "" then
      M.do_search(current_query)
    end
  end)

  -- Copy URL (y)
  bmap(list_buf, "y", function()
    local cursor = vim.api.nvim_win_get_cursor(list_win)
    local idx = cursor[1] - 2
    local item = search_results[idx]
    if item and item.url then
      vim.fn.setreg("+", item.url)
      vim.notify("󰗃 YTNvim: URL copiada para o clipboard: " .. item.url, vim.log.levels.INFO)
    end
  end)

  -- Bounds restriction for j / k
  bmap(list_buf, "k", function()
    local c = vim.api.nvim_win_get_cursor(list_win)
    if c[1] <= 3 then
      vim.api.nvim_win_set_cursor(list_win, { 1, 0 })
      vim.wo[list_win].cursorline = true
    elseif c[1] > 3 then
      vim.api.nvim_win_set_cursor(list_win, { c[1] - 1, c[2] })
      vim.wo[list_win].cursorline = true
    end
  end)
  bmap(list_buf, "<Up>", function()
    local c = vim.api.nvim_win_get_cursor(list_win)
    if c[1] <= 3 then
      vim.api.nvim_win_set_cursor(list_win, { 1, 0 })
      vim.wo[list_win].cursorline = true
    elseif c[1] > 3 then
      vim.api.nvim_win_set_cursor(list_win, { c[1] - 1, c[2] })
      vim.wo[list_win].cursorline = true
    end
  end)
  bmap(list_buf, "j", function()
    local c = vim.api.nvim_win_get_cursor(list_win)
    if c[1] <= 2 then
      if #search_results > 0 then
        vim.api.nvim_win_set_cursor(list_win, { 3, 0 })
        vim.wo[list_win].cursorline = true
      else
        vim.api.nvim_win_set_cursor(list_win, { 1, 0 })
        vim.wo[list_win].cursorline = true
      end
    elseif c[1] < #search_results + 2 then
      vim.api.nvim_win_set_cursor(list_win, { c[1] + 1, c[2] })
      vim.wo[list_win].cursorline = true
    end
  end)
  bmap(list_buf, "<Down>", function()
    local c = vim.api.nvim_win_get_cursor(list_win)
    if c[1] <= 2 then
      if #search_results > 0 then
        vim.api.nvim_win_set_cursor(list_win, { 3, 0 })
        vim.wo[list_win].cursorline = true
      else
        vim.api.nvim_win_set_cursor(list_win, { 1, 0 })
        vim.wo[list_win].cursorline = true
      end
    elseif c[1] < #search_results + 2 then
      vim.api.nvim_win_set_cursor(list_win, { c[1] + 1, c[2] })
      vim.wo[list_win].cursorline = true
    end
  end)

  -- ==============================
  -- 3. Channels Window Keymaps
  -- ==============================
  -- Window navigation (h = Videos list)
  bmap(channel_buf, "h", function()
    if list_win and vim.api.nvim_win_is_valid(list_win) then
      vim.api.nvim_set_current_win(list_win)
    end
  end)
  bmap(channel_buf, "<Left>", function()
    if list_win and vim.api.nvim_win_is_valid(list_win) then
      vim.api.nvim_set_current_win(list_win)
    end
  end)

  -- Select Channel (<CR>)
  bmap(channel_buf, "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(channel_win)
    local idx = cursor[1]
    local ch = channels_list[idx]
    if ch then
      M.load_channel(ch)
      if list_win and vim.api.nvim_win_is_valid(list_win) then
        vim.api.nvim_set_current_win(list_win)
      end
    end
  end)

  -- Add channel (a)
  bmap(channel_buf, "a", function()
    vim.ui.input({ prompt = " Adicionar Canal (URL ou @handle): " }, function(input)
      if input and vim.trim(input) ~= "" then
        local trimmed = vim.trim(input)
        local ch_name = trimmed:match("@([%w%-_]+)") or trimmed:gsub("^https?://[^/]+/", "") or "Canal"
        local ch_url = trimmed
        if not ch_url:find("^https?://") then
          ch_url = "https://www.youtube.com/" .. (ch_url:sub(1, 1) == "@" and ch_url or ("@" .. ch_url))
        end
        table.insert(channels_list, { name = ch_name, url = ch_url })
        render_channel_pane()
      end
    end)
  end)

  -- Delete channel (d)
  bmap(channel_buf, "d", function()
    local cursor = vim.api.nvim_win_get_cursor(channel_win)
    local idx = cursor[1]
    if channels_list[idx] then
      table.remove(channels_list, idx)
      render_channel_pane()
      local new_row = math.max(1, math.min(cursor[1], #channels_list))
      if #channels_list > 0 then
        vim.api.nvim_win_set_cursor(channel_win, { new_row, 0 })
      end
    end
  end)

  -- Bounds restriction for channels j / k
  bmap(channel_buf, "k", function()
    local c = vim.api.nvim_win_get_cursor(channel_win)
    if c[1] > 1 then
      vim.api.nvim_win_set_cursor(channel_win, { c[1] - 1, c[2] })
    end
  end)
  bmap(channel_buf, "<Up>", function()
    local c = vim.api.nvim_win_get_cursor(channel_win)
    if c[1] > 1 then
      vim.api.nvim_win_set_cursor(channel_win, { c[1] - 1, c[2] })
    end
  end)
  bmap(channel_buf, "j", function()
    local c = vim.api.nvim_win_get_cursor(channel_win)
    if c[1] < #channels_list then
      vim.api.nvim_win_set_cursor(channel_win, { c[1] + 1, c[2] })
    end
  end)
  bmap(channel_buf, "<Down>", function()
    local c = vim.api.nvim_win_get_cursor(channel_win)
    if c[1] < #channels_list then
      vim.api.nvim_win_set_cursor(channel_win, { c[1] + 1, c[2] })
    end
  end)
end

function M.open(query)
  if M.is_open() then
    if query and query ~= "" then
      M.do_search(query)
    end
    return
  end

  cached_geom = nil
  setup_highlights()
  channels_list = {}
  local cfg_channels = config.opts.channels or {}
  for i = 1, #cfg_channels do
    local ch = cfg_channels[i]
    channels_list[i] = { name = ch.name, url = ch.url }
  end

  local geom = calc_geometry()
  local border_style = config.opts.border or "rounded"

  -- 1. Left Window: Thumbnail
  thumb_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[thumb_buf].buftype = "nofile"
  vim.bo[thumb_buf].bufhidden = "wipe"
  vim.bo[thumb_buf].swapfile = false
  vim.bo[thumb_buf].modifiable = false

  thumb_win = vim.api.nvim_open_win(thumb_buf, false, {
    relative = "editor",
    width = geom.thumb_w,
    height = geom.height,
    row = geom.start_row,
    col = geom.thumb_col,
    style = "minimal",
    border = border_style,
  })

  -- 2. Middle Window: Videos list
  list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[list_buf].buftype = "nofile"
  vim.bo[list_buf].bufhidden = "wipe"
  vim.bo[list_buf].swapfile = false
  vim.bo[list_buf].modifiable = false

  list_win = vim.api.nvim_open_win(list_buf, true, {
    relative = "editor",
    width = geom.list_w,
    height = geom.height,
    row = geom.start_row,
    col = geom.list_col,
    style = "minimal",
    border = border_style,
  })

  -- 3. Right Window: Saved Channels
  channel_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[channel_buf].buftype = "nofile"
  vim.bo[channel_buf].bufhidden = "wipe"
  vim.bo[channel_buf].swapfile = false
  vim.bo[channel_buf].modifiable = false

  channel_win = vim.api.nvim_open_win(channel_buf, false, {
    relative = "editor",
    width = geom.channel_w,
    height = geom.height,
    row = geom.start_row,
    col = geom.channel_col,
    style = "minimal",
    border = border_style,
  })

  M.thumb_win = thumb_win
  M.list_win = list_win
  M.channel_win = channel_win
  M.thumb_buf = thumb_buf
  M.list_buf = list_buf
  M.channel_buf = channel_buf

  local function update_window_focus()
    local cur_w = vim.api.nvim_get_current_win()
    for _, w in ipairs({ thumb_win, list_win, channel_win }) do
      if w and vim.api.nvim_win_is_valid(w) then
        local is_cur = (w == cur_w)
        local border_hl = is_cur and "YTNvimBorderActive" or "YTNvimBorder"
        -- thumb_win uses element-only highlights (YTNvimSelected), never full-line CursorLine
        local cline_hl = (is_cur and w ~= thumb_win) and "YTNvimCursorLine" or "YTNvimNormal"
        vim.wo[w].winhighlight = string.format("Normal:YTNvimNormal,FloatBorder:%s,CursorLine:%s", border_hl, cline_hl)
      end
    end
  end

  -- Window options
  for _, w in ipairs({ thumb_win, list_win, channel_win }) do
    vim.wo[w].wrap = false
  end
  vim.wo[thumb_win].cursorline = false
  vim.wo[list_win].cursorline = true
  vim.wo[channel_win].cursorline = true
  update_window_focus()

  setup_all_keymaps()

  local ui_augroup = vim.api.nvim_create_augroup("ytnvim_ui", { clear = true })

  -- Autocmds
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = ui_augroup,
    buffer = list_buf,
    callback = on_list_cursor_moved,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = ui_augroup,
    buffer = list_buf,
    callback = function()
      if is_editing_search then
        is_editing_search = false
        vim.bo[list_buf].modifiable = false
        render_list_pane()
        if list_win and vim.api.nvim_win_is_valid(list_win) then
          vim.wo[list_win].cursorline = true
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinEnter", {
    group = ui_augroup,
    callback = function()
      if M.is_open() then
        if thumb_win and vim.api.nvim_win_is_valid(thumb_win) then
          vim.wo[thumb_win].cursorline = false
        end
        if list_win and vim.api.nvim_win_is_valid(list_win) then
          vim.wo[list_win].cursorline = not is_editing_search
        end
        update_window_focus()
        render_thumb_controls()
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = ui_augroup,
    callback = function()
      if not M.is_open() then
        return
      end
      cached_geom = nil
      preview.invalidate_tmux_offset()
      preview.invalidate_drawn()
      local g = calc_geometry()
      if thumb_win and vim.api.nvim_win_is_valid(thumb_win) then
        vim.api.nvim_win_set_config(thumb_win, {
          relative = "editor",
          width = g.thumb_w,
          height = g.height,
          row = g.start_row,
          col = g.thumb_col,
        })
      end
      if list_win and vim.api.nvim_win_is_valid(list_win) then
        vim.api.nvim_win_set_config(list_win, {
          relative = "editor",
          width = g.list_w,
          height = g.height,
          row = g.start_row,
          col = g.list_col,
        })
      end
      if channel_win and vim.api.nvim_win_is_valid(channel_win) then
        vim.api.nvim_win_set_config(channel_win, {
          relative = "editor",
          width = g.channel_w,
          height = g.height,
          row = g.start_row,
          col = g.channel_col,
        })
      end
      local cursor = vim.api.nvim_win_get_cursor(list_win)
      local idx = cursor[1] - 2
      local vid = (idx >= 1 and search_results[idx]) or player.get_current_video() or search_results[1]
      render_thumbnail_pane(vid, true)
      render_list_pane()
      render_channel_pane()
    end,
  })

  vim.api.nvim_create_autocmd("FocusGained", {
    group = ui_augroup,
    callback = function()
      if M.is_open() then
        preview.invalidate_drawn()
        refresh_thumbnail(true)
      end
    end,
  })

  -- Player status listener
  player.add_listener(function()
    if M.is_open() then
      vim.schedule(function()
        if not M.is_open() then
          return
        end
        update_anim_timer()
        render_list_pane()
        preview.invalidate_drawn()
        refresh_thumbnail(true)
      end)
    end
  end)

  -- Initial population
  render_channel_pane()

  if query and vim.trim(query) ~= "" then
    M.do_search(query)
  elseif #search_results > 0 then
    render_list_pane()
    render_thumbnail_pane(search_results[1])
    vim.api.nvim_set_current_win(list_win)
    vim.api.nvim_win_set_cursor(list_win, { 3, 0 })
    vim.wo[list_win].cursorline = true
  else
    render_list_pane()
    render_thumbnail_pane(nil)
    vim.api.nvim_set_current_win(list_win)
    vim.api.nvim_win_set_cursor(list_win, { 1, 0 })
    vim.wo[list_win].cursorline = true
  end
  update_window_focus()
end

function M.close()
  if is_editing_search then
    is_editing_search = false
    pcall(vim.cmd, "stopinsert")
  end
  cached_geom = nil
  if active_date_job then
    pcall(function() active_date_job:kill(9) end)
    active_date_job = nil
  end
  preview.clear_image()
  pcall(vim.api.nvim_clear_autocmds, { group = "ytnvim_ui" })

  if thumb_debounce_timer then
    thumb_debounce_timer:stop()
    if not thumb_debounce_timer:is_closing() then
      thumb_debounce_timer:close()
    end
    thumb_debounce_timer = nil
  end

  if ui_anim_timer then
    ui_anim_timer:stop()
    if not ui_anim_timer:is_closing() then
      ui_anim_timer:close()
    end
    ui_anim_timer = nil
  end

  if thumb_win and vim.api.nvim_win_is_valid(thumb_win) then
    vim.api.nvim_win_close(thumb_win, true)
  end
  thumb_win = nil
  thumb_buf = nil

  if list_win and vim.api.nvim_win_is_valid(list_win) then
    vim.api.nvim_win_close(list_win, true)
  end
  list_win = nil
  list_buf = nil

  if channel_win and vim.api.nvim_win_is_valid(channel_win) then
    vim.api.nvim_win_close(channel_win, true)
  end
  channel_win = nil
  channel_buf = nil

  M.thumb_win = nil
  M.list_win = nil
  M.channel_win = nil
  M.thumb_buf = nil
  M.list_buf = nil
  M.channel_buf = nil
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

function M.refresh_thumbnail(force)
  refresh_thumbnail(force)
end

return M
