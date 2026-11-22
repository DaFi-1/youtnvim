local config = require("ytnvim.config")
local uv = vim.uv or vim.loop

local M = {}

local current_video = nil
local status = "stopped" -- "playing", "paused", "buffering", "stopped"
local pipe = nil
local mpv_handle = nil
local sock_path = string.format("/tmp/ytnvim_%d.sock", uv.getpid())
local listeners = {}
local current_volume = nil

local function get_effective_volume()
  if current_volume == nil then
    current_volume = (config.opts and config.opts.volume) or 30
  end
  return current_volume
end

-- Pre-encoded JSON commands for zero-allocation IPC writes
local CMD_FULLSCREEN = '{"command":["cycle","fullscreen"]}\n'
local CMD_ONTOP      = '{"command":["cycle","ontop"]}\n'
local CMD_PAUSE      = '{"command":["set_property","pause",true]}\n'
local CMD_UNPAUSE    = '{"command":["set_property","pause",false]}\n'
local CMD_QUIT       = '{"command":["quit"]}\n'

local function notify_listeners()
  for cb in pairs(listeners) do
    pcall(cb, status, current_video)
  end
end

function M.add_listener(cb)
  listeners[cb] = true
end

function M.remove_listener(cb)
  listeners[cb] = nil
end

function M.get_status()
  return status
end

function M.get_current_video()
  return current_video
end

local function send_cmd(cmd)
  if not pipe or pipe:is_closing() then
    return
  end
  local encoded = type(cmd) == "string" and cmd or (vim.json.encode({ command = cmd }) .. "\n")
  pipe:write(encoded)
end

local function cleanup_process(force_sync)
  if pipe and not pipe:is_closing() then
    pcall(pipe.write, pipe, CMD_QUIT)
    pipe:close()
  end
  pipe = nil

  if mpv_handle and not mpv_handle:is_closing() then
    local sig = force_sync and 9 or 15
    pcall(mpv_handle.kill, mpv_handle, sig)
    pcall(mpv_handle.close, mpv_handle)
  end
  mpv_handle = nil

  if uv.fs_stat(sock_path) then
    pcall(uv.fs_unlink, sock_path)
  end
end

local function connect_pipe(cb)
  if pipe and not pipe:is_closing() then
    if cb then cb(true) end
    return
  end

  pipe = uv.new_pipe(false)
  pipe:connect(sock_path, function(err)
    if err then
      if pipe and not pipe:is_closing() then
        pipe:close()
      end
      pipe = nil
      if cb then cb(false) end
      return
    end

    local stream_buf = ""
    pipe:read_start(function(rerr, chunk)
      if chunk then
        stream_buf = stream_buf .. chunk
        while true do
          local nl = stream_buf:find("\n", 1, true)
          if not nl then
            break
          end
          local line = stream_buf:sub(1, nl - 1)
          stream_buf = stream_buf:sub(nl + 1)
          line = vim.trim(line)
          if line ~= "" then
            local ok, json = pcall(vim.json.decode, line)
            if ok and type(json) == "table" then
              local ev = json.event
              if ev == "playback-restart" or ev == "unpause" then
                status = "playing"
                vim.schedule(notify_listeners)
              elseif ev == "pause" then
                status = "paused"
                vim.schedule(notify_listeners)
              elseif ev == "end-file" then
                status = "stopped"
                vim.schedule(notify_listeners)
              elseif ev == "property-change" and json.name == "fullscreen" then
                vim.schedule(notify_listeners)
              end
            end
          end
        end
        if #stream_buf > 65536 then
          stream_buf = ""
        end
      else
        stream_buf = ""
        if pipe and not pipe:is_closing() then
          pipe:close()
        end
        pipe = nil
      end
    end)

    pcall(pipe.write, pipe, '{"command":["observe_property",1,"fullscreen"]}\n')
    if cb then cb(true) end
  end)
end

local function start_mpv(video, with_video, cb)
  cleanup_process()

  local args = {
    "--idle",
    string.format("--input-ipc-server=%s", sock_path),
    string.format("--volume=%d", get_effective_volume()),
  }

  if not with_video then
    local audio_args = config.opts.mpv_audio_args or { "--no-video", "--ytdl-format=bestaudio/best" }
    for _, a in ipairs(audio_args) do
      args[#args + 1] = a
    end
  else
    local video_args = config.opts.mpv_video_args or {
      "--force-window=yes",
      "--autofit=55%x55%",
      "--geometry=96%:4%",
      "--ontop",
    }
    for _, a in ipairs(video_args) do
      args[#args + 1] = a
    end
    local quality = config.opts.quality or "1080p"
    local ytdl_format
    if quality == "best" or quality == "max" then
      ytdl_format = "bestvideo+bestaudio/best"
    else
      local height = tostring(quality):gsub("%D", "")
      ytdl_format = (height and height ~= "")
        and ("bestvideo[height<=?" .. height .. "]+bestaudio/best")
        or "bestvideo[height<=?1080]+bestaudio/best"
    end
    args[#args + 1] = "--ytdl-format=" .. ytdl_format
    args[#args + 1] = "--title=ytnvim - " .. (video.title or "YouTube")
  end

  local mpv_cmd = config.opts.player_cmd or "mpv"

  mpv_handle = uv.spawn(mpv_cmd, {
    args = args,
    detached = false,
    stdio = { nil, nil, nil },
  }, function(code, signal)
    status = "stopped"
    cleanup_process()
    vim.schedule(notify_listeners)
  end)

  if not mpv_handle then
    if cb then cb(false, "Falha ao iniciar o processo mpv") end
    return
  end

  -- Wait for socket with timer
  local retries = 0
  local timer = uv.new_timer()
  timer:start(40, 40, function()
    retries = retries + 1
    if uv.fs_stat(sock_path) then
      timer:stop()
      timer:close()
      connect_pipe(function(ok)
        if cb then cb(ok) end
      end)
    elseif retries >= 50 then
      timer:stop()
      timer:close()
      cleanup_process(true)
      if cb then cb(false, "Timeout esperando socket do mpv") end
    end
  end)
end

function M.play(video, with_video)
  if not video or not video.url then
    return
  end

  if with_video == nil then
    with_video = (config.opts.video ~= false)
  end

  current_video = video
  status = "buffering"
  notify_listeners()

  start_mpv(video, with_video, function(ok, err)
    if not ok then
      status = "stopped"
      vim.schedule(function()
        vim.notify("󰗃 YTNvim: Erro ao iniciar player: " .. tostring(err), vim.log.levels.ERROR)
        notify_listeners()
      end)
      return
    end

    send_cmd({ "loadfile", video.url, "replace" })
    send_cmd({ "set_property", "volume", get_effective_volume() })
  end)
end

function M.toggle_fullscreen()
  send_cmd(CMD_FULLSCREEN)
  vim.schedule(notify_listeners)
end

function M.toggle_ontop()
  send_cmd(CMD_ONTOP)
end

function M.toggle_pause()
  if status == "stopped" then
    if current_video then
      M.play(current_video)
    end
    return
  end

  if status == "paused" then
    status = "playing"
    send_cmd(CMD_UNPAUSE)
  else
    status = "paused"
    send_cmd(CMD_PAUSE)
  end
  notify_listeners()
end

function M.stop()
  status = "stopped"
  cleanup_process(true)
  notify_listeners()
  vim.notify("󰓛 YTNvim: Reprodução parada", vim.log.levels.INFO)
end

function M.get_volume()
  return get_effective_volume()
end

function M.set_volume(vol)
  current_volume = math.max(0, math.min(130, vol or 30))
  send_cmd({ "set_property", "volume", current_volume })
end

function M.volume_up(step)
  step = step or 5
  current_volume = math.min(130, get_effective_volume() + step)
  send_cmd({ "add", "volume", step })
end

function M.volume_down(step)
  step = step or 5
  current_volume = math.max(0, get_effective_volume() - step)
  send_cmd({ "add", "volume", -step })
end

-- Cleanup automatically when exiting Neovim
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("ytnvim_player_exit", { clear = true }),
  callback = function()
    cleanup_process(true)
  end,
})

return M
