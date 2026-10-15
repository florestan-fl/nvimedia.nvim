-- nvimedia.nvim - Lyrics / subtitle display window
-- Opens a floating window and updates it via a timer, using the playback
-- position mpv reports to player.lua over IPC (state.time_pos).

local M = {}
local state = require('nvimedia.state')
local srt   = require('nvimedia.srt')

local uv = vim.uv or vim.loop

-- Runtime state for this module
local _win      = nil    -- window handle
local _buf      = nil    -- buffer handle
local _timer    = nil    -- uv timer
local _cues     = {}     -- parsed cue list for the current track
local _last_idx = nil    -- index of last displayed cue (avoid redundant redraws)

-- ─── Window management ────────────────────────────────────────────────────────

local function is_open()
  return _win ~= nil and vim.api.nvim_win_is_valid(_win)
end

local function calc_win_config(lines, max_width)
  -- Place the lyrics window at the bottom-center of the editor
  local cols   = vim.o.columns
  local rows   = vim.o.lines
  local width  = math.min(max_width, cols - 4)
  local height = #lines
  local col    = math.floor((cols - width) / 2)
  local row    = rows - height - 4   -- just above the cmdline
  return {
    relative  = 'editor',
    width     = width,
    height    = height,
    col       = col,
    row       = row,
    style     = 'minimal',
    border    = 'rounded',
    title     = ' ♪ lyrics ',
    title_pos = 'center',
    zindex    = 60,   -- above the status window
  }
end

local function wrap_text(text, max_w)
  local result = {}
  for _, raw_line in ipairs(vim.split(text, '\n', { plain = true })) do
    if #raw_line <= max_w then
      table.insert(result, raw_line)
    else
      -- Word-wrap
      local line = ''
      for word in raw_line:gmatch('%S+') do
        if line == '' then
          line = word
        elseif #line + 1 + #word <= max_w then
          line = line .. ' ' .. word
        else
          table.insert(result, line)
          line = word
        end
      end
      if line ~= '' then table.insert(result, line) end
    end
  end
  return result
end

local function show_cue(cue)
  local MAX_W = math.min(70, vim.o.columns - 6)
  local lines = cue and wrap_text(cue.text, MAX_W) or {}

  if #lines == 0 then
    -- Hide window when no active cue
    if is_open() then
      vim.api.nvim_win_close(_win, true)
      _win = nil
      _buf = nil
    end
    return
  end

  -- Pad lines to equal width (centered text)
  local actual_w = 0
  for _, l in ipairs(lines) do actual_w = math.max(actual_w, #l) end
  local padded = {}
  for _, l in ipairs(lines) do
    local pad = math.floor((actual_w - #l) / 2)
    table.insert(padded, string.rep(' ', pad) .. l)
  end

  if not is_open() then
    _buf = vim.api.nvim_create_buf(false, true)
    vim.bo[_buf].buftype   = 'nofile'
    vim.bo[_buf].bufhidden = 'wipe'
    vim.bo[_buf].swapfile  = false

    _win = vim.api.nvim_open_win(_buf, false, calc_win_config(padded, actual_w + 4))
    vim.wo[_win].wrap      = false
    vim.wo[_win].cursorline = false
    -- Highlight group for lyrics text
    vim.api.nvim_set_hl(0, 'nvimediaLyrics', { link = 'Statement', default = true })
    vim.wo[_win].winhighlight = 'Normal:nvimediaLyrics'
  else
    -- Resize window for new content
    vim.api.nvim_win_set_config(_win, calc_win_config(padded, actual_w + 4))
  end

  vim.bo[_buf].modifiable = true
  vim.api.nvim_buf_set_lines(_buf, 0, -1, false, padded)
  vim.bo[_buf].modifiable = false
end

-- ─── Timer loop ──────────────────────────────────────────────────────────────

local POLL_MS  = 250   -- query mpv position every 250ms
local ADVANCE  = 1   -- show cue 1s early

local function tick()
  if not state.job_id or state.paused or #_cues == 0 then
    _last_idx = nil
    show_cue(nil)
    return
  end

  local cue = srt.active_cue(_cues, state.time_pos or 0, ADVANCE)

  -- Find cue index to avoid redrawing identical content
  local idx = nil
  if cue then
    for i, c in ipairs(_cues) do
      if c == cue then idx = i; break end
    end
  end

  if idx ~= _last_idx then
    _last_idx = idx
    show_cue(cue)
  end
end

-- ─── Public API ──────────────────────────────────────────────────────────────

--- Load an SRT file and start showing lyrics for the current track.
---@param srt_path string
function M.load(srt_path)
  M.stop()  -- clear any previous session

  _cues     = srt.parse(srt_path)
  _last_idx = nil

  if #_cues == 0 then
    vim.notify('[nvimedia] SRT file is empty or could not be parsed: ' .. srt_path, vim.log.levels.WARN)
    return
  end

  vim.notify(('[nvimedia] Loaded %d lyric cues from %s'):format(
    #_cues, vim.fn.fnamemodify(srt_path, ':t')
  ))

  _timer = uv.new_timer()
  _timer:start(0, POLL_MS, vim.schedule_wrap(tick))
end

--- Stop the lyrics display and close the window.
function M.stop()
  if _timer then
    _timer:stop()
    _timer:close()
    _timer    = nil
  end
  _cues     = {}
  _last_idx = nil
  if is_open() then
    vim.api.nvim_win_close(_win, true)
    _win = nil
    _buf = nil
  end
end

--- True if lyrics are currently loaded and running.
function M.is_active()
  return _timer ~= nil
end

--- Toggle lyrics window visibility without stopping the timer.
function M.toggle_visible()
  if is_open() then
    vim.api.nvim_win_close(_win, true)
    _win = nil
    _buf = nil
  else
    -- Will reappear on next tick when a cue is active
    _last_idx = nil
  end
end

return M
