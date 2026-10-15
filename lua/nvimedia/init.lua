-- nvimedia.nvim - A media player plugin for Neovim (audio + video via mpv)
-- Usage: require('nvimedia').setup({})

local M = {}
local state  = require('nvimedia.state')
local player = require('nvimedia.player')
local ui     = require('nvimedia.ui')
local queue  = require('nvimedia.queue')
local lyrics = require('nvimedia.lyrics')

local default_config = {
  -- Supported extensions (audio + video)
  media_extensions = {
    '.mp3', '.ogg', '.wav', '.flac', '.aac', '.m4a', '.opus', '.wma',
    '.mp4', '.mkv', '.avi', '.mov', '.webm', '.flv', '.wmv', '.m4v', '.ts', '.ogv',
  },
  shuffle      = false,
  repeat_mode  = 'none',   -- 'none' | 'queue' | 'track'
  volume       = 80,
  keymaps = {
    toggle_play  = '<Space>',
    next_track   = 'n',
    prev_track   = 'p',
    seek_forward = 'f',
    seek_back    = 'b',
    volume_up    = '+',
    volume_down  = '-',
    shuffle      = 's',
    repeat_mode  = 'r',
    close        = 'q',
  },
  -- 'top-right' | 'top-left' | 'bottom-right' | 'bottom-left' | 'center'
  window_position = 'bottom-right',
  subtitles = {
    -- Automatically use a subtitle file with the same name next to the media
    -- (song.mp3 -> song.srt). :MedSub overrides it per file.
    auto       = true,
    extensions = { '.srt' },
  },
}

function M.setup(user_config)
  state.config = vim.tbl_deep_extend('force', default_config, user_config or {})
  player.detect_backend()
  M._setup_commands()
  M._setup_autocmds()
end

function M._setup_commands()
  -- Play a file or directory, optionally with an SRT lyrics/subtitle file:
  --   :MedPlay song.mp3 song.srt
  vim.api.nvim_create_user_command('MedPlay', function(opts)
    local path     = opts.fargs[1]
    local srt_path = opts.fargs[2]
    if not path or path == '' then path = vim.fn.expand('%:p') end
    M.play(path, { subtitle = srt_path })
  end, { nargs = '*', complete = 'file', desc = 'Play a file or directory [srt_file]' })

  -- Queue a file or directory (add to end of queue)
  vim.api.nvim_create_user_command('MedQueue', function(opts)
    local path = opts.args ~= '' and opts.args or vim.fn.expand('%:p')
    M.enqueue(path)
  end, { nargs = '?', complete = 'file', desc = 'Add file/dir to queue' })

  vim.api.nvim_create_user_command('MedSub', function(opts)
    if opts.bang then
      M.set_subtitle(false)
    elseif opts.args ~= '' then
      M.set_subtitle(opts.args)
    else
      local sub = state.sub_path
      vim.notify('[nvimedia] Subtitle: ' .. (sub and vim.fn.fnamemodify(sub, ':~') or '(none)'))
    end
  end, {
    nargs = '?', bang = true, complete = 'file',
    desc  = 'Set subtitle file of the current item (! = disable, no arg = show)',
  })

  vim.api.nvim_create_user_command('MedLyrics',  M.toggle_lyrics, { desc = 'Toggle lyrics/subtitle window' })
  vim.api.nvim_create_user_command('MedStop',    M.stop,          { desc = 'Stop playback' })
  vim.api.nvim_create_user_command('MedPause',   M.pause,         { desc = 'Pause' })
  vim.api.nvim_create_user_command('MedResume',  M.resume,        { desc = 'Resume' })
  vim.api.nvim_create_user_command('MedToggle',  M.toggle,        { desc = 'Toggle pause/resume' })
  vim.api.nvim_create_user_command('MedNext',    M.next_track,    { desc = 'Next item' })
  vim.api.nvim_create_user_command('MedPrev',    M.prev_track,    { desc = 'Previous item' })
  vim.api.nvim_create_user_command('MedStatus',  M.show_status,   { desc = 'Show status window' })
  vim.api.nvim_create_user_command('MedClear',   M.clear_queue,   { desc = 'Clear queue and stop' })
  vim.api.nvim_create_user_command('MedShuffle', M.toggle_shuffle,{ desc = 'Toggle shuffle' })

  vim.api.nvim_create_user_command('MedVolume', function(opts)
    local vol = tonumber(opts.args)
    if vol then M.set_volume(vol)
    else vim.notify('[nvimedia] Usage: MedVolume <0-100>', vim.log.levels.WARN) end
  end, { nargs = 1, desc = 'Set volume 0-100' })

  vim.api.nvim_create_user_command('MedSeek', function(opts)
    local secs = tonumber(opts.args)
    if secs then M.seek(secs)
    else vim.notify('[nvimedia] Usage: MedSeek <seconds> (negative = backward)', vim.log.levels.WARN) end
  end, { nargs = 1, desc = 'Seek relative seconds (e.g. MedSeek -10)' })
end

function M._setup_autocmds()
  local group = vim.api.nvim_create_augroup('nvimedia', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group    = group,
    pattern  = 'nvimediaTrackChanged',
    callback = function() ui.refresh() end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group    = group,
    callback = function() player.stop_job() end,
  })
end

-- ─── Public API ───────────────────────────────────────────────────────────────

---@param path string file or directory
---@param opts? { subtitle?: string } subtitle file (single file only)
function M.play(path, opts)
  path = vim.fn.expand(path)
  if path == '' then
    vim.notify('[nvimedia] No path given', vim.log.levels.WARN)
    return
  end

  local tracks = queue.resolve_path(path)
  if #tracks == 0 then
    vim.notify('[nvimedia] No supported audio files found in: ' .. path, vim.log.levels.WARN)
    return
  end
  if opts and opts.subtitle and opts.subtitle ~= '' then
    if #tracks > 1 then
      vim.notify(
        '[nvimedia] SRT file ignored: only supported when playing a single track, not a directory/queue',
        vim.log.levels.WARN
      )
    else
      local sub = M._resolve_subtitle(opts.subtitle)
      if sub then state.subtitles[tracks[1]] = sub end
    end
  end
  state.queue       = tracks
  state.queue_index = 1
  if state.config.shuffle then queue.shuffle_in_place(state.queue) end

  player.play_current()
end

--- Add a file or directory to the end of the queue
---@param path string
function M.enqueue(path)
  path = vim.fn.expand(path)
  local tracks = queue.resolve_path(path)
  if #tracks == 0 then
    vim.notify('[nvimedia] No supported audio files found in: ' .. path, vim.log.levels.WARN)
    return
  end
  local first_new = #state.queue + 1
  for _, t in ipairs(tracks) do table.insert(state.queue, t) end
  vim.notify(('[nvimedia] Queued %d item(s). Total: %d'):format(#tracks, #state.queue))
  if not state.job_id then
    -- Nothing playing: start with what was just queued, not the old item
    state.queue_index = first_new
    player.play_current()
  end
end

function M.stop()          player.stop() end
function M.pause()         player.pause() end
function M.resume()        player.resume() end
function M.toggle()        player.toggle() end
function M.next_track()    player.next_track() end
function M.prev_track()    player.prev_track() end
function M.seek(secs)      player.seek(secs) end
function M.show_status()   ui.open() end
function M.clear_queue()   player.stop(); state.queue = {}; state.queue_index = 1; ui.refresh() end

function M.toggle_shuffle() player.toggle_shuffle() end
function M.set_volume(vol)   player.set_volume(vol) end

---@return string|nil absolute path if readable
function M._resolve_subtitle(path)
  path = vim.fn.fnamemodify(vim.fn.expand(path), ':p')
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify('[nvimedia] Subtitle not found: ' .. path, vim.log.levels.WARN)
    return nil
  end
  return path
end

--- Set the subtitle file of the current item, overriding the automatic lookup.
---@param path string|false subtitle file, or false to disable subtitles
function M.set_subtitle(path)
  local track = state.current_track()
  if not track then
    vim.notify('[nvimedia] Queue is empty', vim.log.levels.WARN)
    return
  end
  if path then
    path = M._resolve_subtitle(path)
    if not path then return end
  end
  state.subtitles[track] = path
  player.reload_subtitle()
  vim.notify('[nvimedia] Subtitle: ' .. (path and vim.fn.fnamemodify(path, ':~') or 'off'))
end

function M.toggle_lyrics()
  if not lyrics.is_active() then
    vim.notify('[nvimedia] No lyrics loaded for the current track', vim.log.levels.WARN)
    return
  end
  lyrics.toggle_visible()
end

return M
