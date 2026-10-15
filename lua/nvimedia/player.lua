-- nvimedia.nvim - Player backend (mpv only)
-- mpv handles both audio and video natively.
-- Each mpv instance gets its own JSON IPC socket (see ipc.lua).

local M = {}
local state     = require('nvimedia.state')
local ipc       = require('nvimedia.ipc')
local subtitles = require('nvimedia.subtitles')
local lyrics    = require('nvimedia.lyrics')

-- IPC session of the running mpv instance
local session = nil

-- mpv exit code when it was killed by a signal / Ctrl+C in its window
local MPV_EXIT_SIGNAL = 4

-- ─── Backend Detection ────────────────────────────────────────────────────────

function M.detect_backend()
  if vim.fn.executable('mpv') == 1 then
    state.backend = 'mpv'
  else
    vim.notify('[nvimedia] mpv not found. Please install mpv.', vim.log.levels.ERROR)
  end
end

-- ─── IPC ─────────────────────────────────────────────────────────────────────

local function emit_track_changed()
  vim.schedule(function()
    vim.api.nvim_exec_autocmds('User', { pattern = 'nvimediaTrackChanged' })
  end)
end

local function mpv_command(args)
  if session then session:command(args) end
end

local OBSERVED = { 'time-pos', 'duration', 'pause' }

local function on_mpv_event(msg)
  if msg.event ~= 'property-change' then return end
  if msg.name == 'time-pos' then
    state.time_pos = msg.data
  elseif msg.name == 'duration' then
    state.duration = msg.data
  elseif msg.name == 'pause' and type(msg.data) == 'boolean' then
    -- Keeps us in sync when pausing from the mpv window itself
    if state.paused ~= msg.data then
      state.paused = msg.data
      emit_track_changed()
    end
  end
end

-- ─── Build Command ────────────────────────────────────────────────────────────

---@param path string absolute path to media file
---@param socket string IPC socket path
---@param sub string|nil subtitle file
---@return string[]
local function build_cmd(path, socket, sub)
  local vol  = state.config.volume or 80
  local cmd = {
    'mpv',
    '--really-quiet',
    ('--volume=%d'):format(vol),
    ('--input-ipc-server=%s'):format(socket),
    -- Subtitles are resolved by nvimedia (auto .srt lookup / :MedSub)
    '--sub-auto=no',
  }

  if state.is_video(path) then
    -- '$' starts a property expansion in --title, escape it
    local name = vim.fn.fnamemodify(path, ':t'):gsub('%$', '$$')
    table.insert(cmd, ('--title=%s'):format(name))
    -- Keep aspect ratio, allow user to resize
    table.insert(cmd, '--keepaspect')
    if sub then table.insert(cmd, ('--sub-file=%s'):format(sub)) end
  else
    -- Audio-only files: suppress video output entirely (no blank window).
    -- Subtitles (lyrics) are shown in the status window instead.
    table.insert(cmd, '--no-video')
  end

  table.insert(cmd, '--')
  table.insert(cmd, path)
  return cmd
end

-- ─── Lyrics helper ───────────────────────────────────────────────────────────

--- Show the lyrics window for the subtitle of the current track (manual
--- :MedPlay <file> <srt> / :MedSub, or the auto-detected <name>.srt).
--- No subtitle: silently close any window left from a previous track.
--- Videos are skipped, mpv renders their subtitles in its own window.
local function sync_lyrics()
  local track = state.current_track()
  if state.job_id and state.sub_path and not state.is_video(track) then
    lyrics.load(state.sub_path)
  else
    lyrics.stop()
  end
end

-- ─── Core ────────────────────────────────────────────────────────────────────

local function reset_playback()
  state.paused   = false
  state.time_pos = nil
  state.duration = nil
end

local function load_subtitle(track)
  state.sub_path = subtitles.find(track)
  state.cues     = state.sub_path and subtitles.parse(state.sub_path) or nil
end

--- Kill the running mpv (if any). Its on_exit callback is ignored afterwards,
--- because it no longer matches state.job_id.
function M.stop_job()
  if not state.job_id then return end
  local id = state.job_id
  state.job_id = nil
  if session then session:close(); session = nil end
  vim.fn.jobstop(id)
  reset_playback()
end

local on_track_end

local function start()
  if not state.backend then
    vim.notify('[nvimedia] No backend available', vim.log.levels.ERROR)
    return
  end

  local track = state.current_track()
  if not track then
    vim.notify('[nvimedia] Queue is empty', vim.log.levels.INFO)
    return
  end

  M.stop_job()

  -- A unique socket per instance: a previous mpv that is still shutting down
  -- can never remove (or be controlled through) the socket of the new one.
  local socket = vim.fn.tempname() .. '.sock'
  load_subtitle(track)
  local cmd = build_cmd(track, socket, state.sub_path)

  state.play_start = os.time()
  reset_playback()

  local job_id
  job_id = vim.fn.jobstart(cmd, {
    on_exit = function(_, exit_code, _)
      os.remove(socket)
      -- Stale job: it was stopped or replaced by another track
      if job_id ~= state.job_id then return end
      state.job_id = nil
      if session then session:close(); session = nil end
      reset_playback()
      on_track_end(exit_code)
    end,
  })

  if job_id <= 0 then
    vim.notify('[nvimedia] Failed to start mpv', vim.log.levels.ERROR)
    return
  end
  state.job_id = job_id

  session = ipc.connect(socket, on_mpv_event)
  for i, prop in ipairs(OBSERVED) do
    session:command({ 'observe_property', i, prop })
  end

  sync_lyrics()

  local icon = state.is_video(track) and '🎬' or '♫'
  vim.notify(('%s %s'):format(icon, state.current_track_name()))
  emit_track_changed()
end

--- Play the current queue item (user initiated).
function M.play_current()
  state.failures = 0
  start()
end

---@return integer|nil index of the item after the current one, honoring repeat
local function next_index()
  if state.queue_index < #state.queue then
    return state.queue_index + 1
  elseif (state.config.repeat_mode or 'none') == 'queue' then
    return 1
  end
  return nil
end

on_track_end = function(exit_code)
  if exit_code == MPV_EXIT_SIGNAL then
    -- mpv was killed from outside / Ctrl+C in its window: treat as stop
    emit_track_changed()
    return
  end

  if exit_code ~= 0 then
    state.failures = state.failures + 1
    vim.notify(('[nvimedia] mpv could not play %s (exit code %d)')
      :format(state.current_track_name(), exit_code), vim.log.levels.WARN)
    if state.failures >= #state.queue then
      vim.notify('[nvimedia] No playable item left in queue', vim.log.levels.ERROR)
      emit_track_changed()
      return
    end
  else
    state.failures = 0
    if state.config.repeat_mode == 'track' then
      start()
      return
    end
  end

  local idx = next_index()
  if idx then
    state.queue_index = idx
    start()
  else
    vim.notify('[nvimedia] ■ End of queue')
    lyrics.stop()
    emit_track_changed()
  end
end

-- ─── Controls ────────────────────────────────────────────────────────────────

function M.stop()
  M.stop_job()
  lyrics.stop()
  vim.notify('[nvimedia] ■ Stopped')
  emit_track_changed()
end

function M.pause()
  if not state.job_id then
    vim.notify('[nvimedia] Nothing is playing', vim.log.levels.WARN)
    return
  end
  if state.paused then return end
  mpv_command({ 'set_property', 'pause', true })
  state.paused = true
  vim.notify('[nvimedia] ⏸ Paused')
  emit_track_changed()
end

function M.resume()
  if not state.job_id then
    vim.notify('[nvimedia] Nothing is playing', vim.log.levels.WARN)
    return
  end
  if not state.paused then return end
  mpv_command({ 'set_property', 'pause', false })
  state.paused = false
  vim.notify('[nvimedia] ▶ Resumed')
  emit_track_changed()
end

function M.toggle()
  if not state.job_id then
    -- Stopped: start the current queue item again
    if #state.queue > 0 then M.play_current()
    else vim.notify('[nvimedia] Nothing is playing', vim.log.levels.WARN) end
    return
  end
  if state.paused then M.resume() else M.pause() end
end

function M.next_track()
  if #state.queue == 0 then
    vim.notify('[nvimedia] Queue is empty', vim.log.levels.WARN)
    return
  end
  local idx = next_index()
  if not idx then
    vim.notify('[nvimedia] Already at last item')
    return
  end
  state.queue_index = idx
  M.play_current()
end

function M.prev_track()
  if #state.queue == 0 then
    vim.notify('[nvimedia] Queue is empty', vim.log.levels.WARN)
    return
  end
  local elapsed = state.time_pos
    or (state.play_start and (os.time() - state.play_start))
    or 0
  -- Within 3s of start AND not at first track: go to previous
  -- Otherwise (>3s in, or at track 1): restart current track
  if elapsed <= 3 and state.queue_index > 1 then
    state.queue_index = state.queue_index - 1
  end
  M.play_current()
end

function M.set_volume(vol)
  vol = math.floor(math.max(0, math.min(100, vol)) + 0.5)
  state.config.volume = vol
  mpv_command({ 'set_property', 'volume', vol })
  vim.notify(('[nvimedia] Volume: %d%%'):format(vol))
  emit_track_changed()
end

function M.seek(seconds)
  if not state.job_id then
    vim.notify('[nvimedia] Nothing is playing', vim.log.levels.WARN)
    return
  end
  -- mpv seek: positive = forward, negative = backward, mode "relative"
  mpv_command({ 'seek', seconds, 'relative' })
end

function M.cycle_repeat()
  local modes   = state.REPEAT_MODES
  local current = state.config.repeat_mode or 'none'
  local next_mode = modes[1]
  for i, m in ipairs(modes) do
    if m == current then next_mode = modes[(i % #modes) + 1]; break end
  end
  state.config.repeat_mode = next_mode
  vim.notify(('[nvimedia] Repeat: %s'):format(next_mode))
  emit_track_changed()
end

function M.toggle_shuffle()
  state.config.shuffle = not state.config.shuffle
  vim.notify('[nvimedia] Shuffle ' .. (state.config.shuffle and 'ON' or 'OFF'))
  emit_track_changed()
end

--- Re-resolve the subtitle of the current track (after :MedSub) and apply it
--- to the running mpv.
function M.reload_subtitle()
  local track = state.current_track()
  if not track then return end
  load_subtitle(track)
  if state.job_id and state.is_video(track) then
    if state.sub_path then
      mpv_command({ 'sub-add', state.sub_path, 'select' })
    else
      mpv_command({ 'set_property', 'sid', 'no' })
    end
  end
  sync_lyrics()
  emit_track_changed()
end

return M
