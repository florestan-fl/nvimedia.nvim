-- nvimedia.nvim - Shared state

local M = {}

M.job_id       = nil      -- current nvim job id
M.queue        = {}       -- list of file paths
M.queue_index  = 1        -- 1-based index into M.queue
M.paused       = false
M.backend      = nil      -- 'mpv' | nil
M.play_start   = nil      -- os.time() when current track started
M.time_pos     = nil      -- playback position (seconds), reported by mpv
M.duration     = nil      -- track duration (seconds), reported by mpv
M.failures     = 0        -- consecutive tracks mpv failed to play
M.subtitles    = {}       -- manual overrides: media path -> subtitle path | false
M.sub_path     = nil      -- subtitle file of the current track
M.cues         = nil      -- parsed cues of M.sub_path
M.config       = {}

M.REPEAT_MODES = { 'none', 'queue', 'track' }

-- Extensions treated as video for the UI icon (playback is identical either way)
M.VIDEO_EXTENSIONS = {
  ['.mp4']  = true, ['.mkv'] = true, ['.avi'] = true, ['.mov'] = true,
  ['.webm'] = true, ['.flv'] = true, ['.wmv'] = true, ['.m4v'] = true,
  ['.ts']   = true, ['.ogv'] = true,
}

function M.current_track()
  if #M.queue == 0 then return nil end
  return M.queue[M.queue_index]
end

function M.current_track_name()
  local t = M.current_track()
  if not t then return '(none)' end
  return vim.fn.fnamemodify(t, ':t')
end

function M.is_video(path)
  if not path then return false end
  local ext = path:match('(%.[^%.]+)$')
  if not ext then return false end
  return M.VIDEO_EXTENSIONS[ext:lower()] ~= nil
end

return M
