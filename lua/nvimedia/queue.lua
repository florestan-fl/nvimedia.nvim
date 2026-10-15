-- nvimedia.nvim - Queue management

local M = {}
local state = require('nvimedia.state')

local DEFAULT_EXTENSIONS = {
  -- Audio
  '.mp3', '.ogg', '.wav', '.flac', '.aac', '.m4a', '.opus', '.wma',
  -- Video
  '.mp4', '.mkv', '.avi', '.mov', '.webm', '.flv', '.wmv', '.m4v', '.ts', '.ogv',
}

function M.is_media(path)
  local ext = path:match('(%.[^%.]+)$')
  if not ext then return false end
  ext = ext:lower()
  local exts = state.config.media_extensions or DEFAULT_EXTENSIONS
  for _, e in ipairs(exts) do
    if ext == e then return true end
  end
  return false
end

---@param path string
---@return string[]
function M.resolve_path(path)
  path = vim.fn.fnamemodify(path, ':p')

  if vim.fn.filereadable(path) == 1 then
    if M.is_media(path) then
      return { path }
    else
      vim.notify(('[nvimedia] Not a supported media file: %s'):format(path), vim.log.levels.WARN)
      return {}
    end
  end

  if vim.fn.isdirectory(path) == 1 then
    local results = {}
    local raw = vim.fn.globpath(path, '**/*', false, true)
    if #raw == 0 then
      raw = vim.fn.globpath(path, '*', false, true)
    end
    for _, f in ipairs(raw) do
      if vim.fn.filereadable(f) == 1 and M.is_media(f) then
        table.insert(results, f)
      end
    end
    table.sort(results)
    return results
  end

  vim.notify(('[nvimedia] Path not found: %s'):format(path), vim.log.levels.WARN)
  return {}
end

function M.shuffle_in_place(t)
  math.randomseed(os.time())
  for i = #t, 2, -1 do
    local j = math.random(i)
    t[i], t[j] = t[j], t[i]
  end
end

return M
