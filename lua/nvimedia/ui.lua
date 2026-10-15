-- nvimedia.nvim - Status window UI

local M = {}
local state     = require('nvimedia.state')
local player    = require('nvimedia.player')
local subtitles = require('nvimedia.subtitles')

local uv = vim.uv or vim.loop

local WIDTH      = 54
local REFRESH_MS = 500

local _win   = nil
local _buf   = nil
local _timer = nil
local _ns    = vim.api.nvim_create_namespace('nvimedia_hl')

local function is_open()
  return _win ~= nil and vim.api.nvim_win_is_valid(_win)
end

local function status_icon()
  if not state.job_id then return '■' end
  if state.paused      then return '⏸' end
  return '▶'
end

local function media_icon(path)
  return state.is_video(path) and '🎬' or '♫'
end

local function repeat_label()
  local m = state.config.repeat_mode or 'none'
  return ({ none = '→ ', queue = '🔁', track = '🔂' })[m] or '  '
end

local function shuffle_label()
  return (state.config.shuffle) and '🔀' or '  '
end

--- Truncate `s` to `width` display cells (multibyte / emoji aware).
local function fit(s, width)
  if vim.fn.strdisplaywidth(s) <= width then return s end
  local out = ''
  for i = 0, vim.fn.strchars(s) - 1 do
    local c = vim.fn.strcharpart(s, i, 1)
    if vim.fn.strdisplaywidth(out .. c) > width - 1 then break end
    out = out .. c
  end
  return out .. '…'
end

local function fmt_time(t)
  if not t then return '--:--' end
  t = math.floor(t)
  local h, m, s = math.floor(t / 3600), math.floor(t % 3600 / 60), t % 60
  if h > 0 then return ('%d:%02d:%02d'):format(h, m, s) end
  return ('%d:%02d'):format(m, s)
end

local function progress_line()
  local times = ('%s / %s'):format(fmt_time(state.time_pos), fmt_time(state.duration))
  local bar_w = WIDTH - 6 - #times
  local ratio = 0
  if state.time_pos and state.duration and state.duration > 0 then
    ratio = math.max(0, math.min(1, state.time_pos / state.duration))
  end
  local done = math.floor(bar_w * ratio + 0.5)
  return ('    %s%s %s'):format(string.rep('━', done), string.rep('─', bar_w - done), times)
end

local function format_queue_line(i, track)
  local name   = vim.fn.fnamemodify(track, ':t')
  local cursor = (i == state.queue_index) and (status_icon() .. ' ') or '  '
  local prefix = ('%s%s %2d. '):format(cursor, media_icon(track), i)
  return prefix .. fit(name, WIDTH - vim.fn.strdisplaywidth(prefix) - 1)
end

local function footer_lines()
  local km = state.config.keymaps or {}
  local items = {
    { km.toggle_play, 'play/pause' },
    { km.next_track,  'next' },
    { km.prev_track,  'prev' },
    { km.seek_forward and km.seek_back and (km.seek_forward .. '/' .. km.seek_back), 'seek ±10s' },
    { km.volume_up and km.volume_down and (km.volume_up .. '/' .. km.volume_down), 'volume' },
    { km.shuffle,     'shuffle' },
    { km.repeat_mode, 'repeat' },
    { km.close,       'close' },
  }
  local lines, cur = {}, ''
  for _, it in ipairs(items) do
    if it[1] then
      local entry = it[1] .. ' ' .. it[2]
      if cur ~= '' and vim.fn.strdisplaywidth(cur .. '   ' .. entry) > WIDTH - 1 then
        table.insert(lines, ' ' .. cur)
        cur = entry
      else
        cur = (cur == '') and entry or (cur .. '   ' .. entry)
      end
    end
  end
  if cur ~= '' then table.insert(lines, ' ' .. cur) end
  return lines
end

---@return string[] lines, table<integer, string> highlight group per line (0-based)
local function build_lines()
  local lines, hls = {}, {}
  local function add(line, hl)
    table.insert(lines, line)
    if hl then hls[#lines - 1] = hl end
  end
  local sep = string.rep('─', WIDTH)

  local vol = state.config and state.config.volume or 80
  add((' ▶ nvimedia  %s %s  vol:%d%% '):format(shuffle_label(), repeat_label(), vol), 'nvimediaHeader')
  add(sep, 'nvimediaHeader')

  local track = state.current_track()
  if track then
    local prefix = (' %s  %s  '):format(status_icon(), media_icon(track))
    local name   = vim.fn.fnamemodify(track, ':t')
    add(prefix .. fit(name, WIDTH - vim.fn.strdisplaywidth(prefix) - 1), 'nvimediaPlaying')
    add(fit(('    📁 %s'):format(vim.fn.fnamemodify(track, ':h:t')), WIDTH), 'nvimediaDimmed')
    if state.job_id then add(progress_line(), 'nvimediaDimmed') end
    if state.is_video(track) then
      add('    (video — mpv window)', 'nvimediaVideo')
    end
    if state.sub_path then
      add(fit(('    📝 %s'):format(vim.fn.fnamemodify(state.sub_path, ':t')), WIDTH), 'nvimediaDimmed')
      if state.job_id and not state.is_video(track) then
        -- Audio: show the lyrics here, mpv has no window to render them
        local cur, upcoming = subtitles.at(state.cues, state.time_pos)
        add(fit('    ' .. (cur and cur.text or '…'), WIDTH), 'nvimediaLyric')
        add(fit('    ' .. (upcoming and upcoming.text or ''), WIDTH), 'nvimediaDimmed')
      end
    end
  else
    add(' (nothing playing)', 'nvimediaDimmed')
    add('')
  end

  add(sep, 'nvimediaHeader')

  local q = state.queue
  if #q == 0 then
    add('  (empty queue)', 'nvimediaDimmed')
  else
    local s = math.max(1, state.queue_index - 3)
    local e = math.min(#q, s + 9)
    s = math.max(1, math.min(s, e - 9))
    if s > 1 then add(('  … %d more above'):format(s - 1), 'nvimediaDimmed') end
    for i = s, e do
      local hl = (i == state.queue_index) and 'nvimediaPlaying'
        or (state.is_video(q[i]) and 'nvimediaVideo' or nil)
      add(format_queue_line(i, q[i]), hl)
    end
    if e < #q then add(('  … %d more below'):format(#q - e), 'nvimediaDimmed') end
  end

  add(sep, 'nvimediaHeader')
  for _, l in ipairs(footer_lines()) do add(l, 'nvimediaDimmed') end

  return lines, hls
end

local function calc_pos(width, height)
  local pos  = state.config.window_position or 'bottom-right'
  local cols = vim.o.columns
  local rows = vim.o.lines
  local col, row
  if     pos == 'top-right'    then col = cols - width - 2; row = 1
  elseif pos == 'top-left'     then col = 1;                row = 1
  elseif pos == 'bottom-left'  then col = 1;                row = rows - height - 3
  elseif pos == 'center'       then col = (cols-width)/2;   row = (rows-height)/2
  else                              col = cols - width - 2; row = rows - height - 3
  end
  return math.max(0, math.floor(col)), math.max(0, math.floor(row))
end

local function win_config(height)
  local col, row = calc_pos(WIDTH, height)
  return { relative = 'editor', width = WIDTH, height = height, col = col, row = row }
end

local function render()
  local lines, hls = build_lines()
  vim.bo[_buf].modifiable = true
  vim.api.nvim_buf_set_lines(_buf, 0, -1, false, lines)
  vim.bo[_buf].modifiable = false
  M._apply_highlights(lines, hls)
  if vim.api.nvim_win_get_height(_win) ~= #lines then
    vim.api.nvim_win_set_config(_win, win_config(#lines))
  end
end

local function stop_timer()
  if _timer then
    _timer:stop()
    if not _timer:is_closing() then _timer:close() end
    _timer = nil
  end
end

function M.open()
  if is_open() then M.refresh(); vim.api.nvim_set_current_win(_win); return end

  _buf = vim.api.nvim_create_buf(false, true)
  vim.bo[_buf].buftype   = 'nofile'
  vim.bo[_buf].bufhidden = 'wipe'
  vim.bo[_buf].swapfile  = false
  vim.bo[_buf].filetype  = 'nvimedia'

  local lines = build_lines()
  local cfg = win_config(#lines)
  cfg.style     = 'minimal'
  cfg.border    = 'rounded'
  cfg.title     = ' ▶ nvimedia '
  cfg.title_pos = 'center'
  _win = vim.api.nvim_open_win(_buf, true, cfg)
  vim.wo[_win].wrap = false

  render()
  M._setup_keymaps()

  -- Live position / lyrics
  _timer = uv.new_timer()
  _timer:start(REFRESH_MS, REFRESH_MS, vim.schedule_wrap(function()
    if not is_open() then stop_timer(); return end
    if state.job_id then render() end
  end))
end

function M.close()
  stop_timer()
  if is_open() then
    vim.api.nvim_win_close(_win, true)
  end
  _win = nil
  _buf = nil
end

function M.refresh()
  if not is_open() then return end
  render()
end

function M._apply_highlights(lines, hls)
  if not _buf or not vim.api.nvim_buf_is_valid(_buf) then return end
  vim.api.nvim_set_hl(0, 'nvimediaPlaying', { link = 'DiagnosticOk',   default = true })
  vim.api.nvim_set_hl(0, 'nvimediaHeader',  { link = 'Title',          default = true })
  vim.api.nvim_set_hl(0, 'nvimediaDimmed',  { link = 'Comment',        default = true })
  vim.api.nvim_set_hl(0, 'nvimediaVideo',   { link = 'DiagnosticInfo', default = true })
  vim.api.nvim_set_hl(0, 'nvimediaLyric',   { link = 'String',         default = true })

  vim.api.nvim_buf_clear_namespace(_buf, _ns, 0, -1)
  for ln, group in pairs(hls) do
    vim.api.nvim_buf_set_extmark(_buf, _ns, ln, 0, { end_col = #lines[ln + 1], hl_group = group })
  end
end

function M._setup_keymaps()
  if not _buf then return end
  local km = state.config.keymaps or {}

  local function map(key, fn)
    if not key then return end
    vim.keymap.set('n', key, fn, { buffer = _buf, nowait = true, silent = true })
  end

  map(km.toggle_play,  function() player.toggle();      M.refresh() end)
  map(km.next_track,   function() player.next_track();  M.refresh() end)
  map(km.prev_track,   function() player.prev_track();  M.refresh() end)
  map(km.seek_forward, function() player.seek(10);      M.refresh() end)
  map(km.seek_back,    function() player.seek(-10);     M.refresh() end)
  map(km.volume_up,    function()
    player.set_volume((state.config.volume or 80) + 5)
    M.refresh()
  end)
  map(km.volume_down,  function()
    player.set_volume((state.config.volume or 80) - 5)
    M.refresh()
  end)
  map(km.shuffle,      function() player.toggle_shuffle(); M.refresh() end)
  map(km.repeat_mode,  function() player.cycle_repeat();   M.refresh() end)
  map(km.close,        M.close)

  vim.api.nvim_create_autocmd('BufLeave', {
    buffer   = _buf,
    once     = true,
    callback = M.close,
  })
end

return M
