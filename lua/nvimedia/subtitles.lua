-- nvimedia.nvim - Subtitle / lyrics (.srt) handling

local M = {}
local state = require('nvimedia.state')

--- Subtitle file to use for a media file:
---   1. the one set manually (:MedSub / play(path, { subtitle = ... })),
---   2. otherwise, if subtitles.auto is on, a file next to the media with the
---      same name and a subtitle extension (song.mp3 -> song.srt).
---@param media string absolute path
---@return string|nil
function M.find(media)
  local manual = state.subtitles[media]
  if manual ~= nil then
    return manual or nil  -- false = explicitly disabled for this file
  end

  local cfg = state.config.subtitles or {}
  if not cfg.auto then return nil end

  local stem = vim.fn.fnamemodify(media, ':r')
  for _, ext in ipairs(cfg.extensions or { '.srt' }) do
    for _, candidate in ipairs({ stem .. ext, stem .. ext:upper() }) do
      if vim.fn.filereadable(candidate) == 1 then return candidate end
    end
  end
  return nil
end

local function timestamp(h, m, s, frac)
  return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
    + tonumber(frac) / (10 ^ #frac)
end

local function clean(text)
  return (text
    :gsub('<[^>]->', '')          -- <i>, <font ...>
    :gsub('{\\[^}]*}', '')        -- {\an8}
    :gsub('^%s+', '')
    :gsub('%s+$', ''))
end

--- Parse a .srt file into a list of cues sorted by start time.
---@param path string
---@return { start: number, stop: number, text: string }[]|nil
function M.parse(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    vim.notify('[nvimedia] Could not read subtitle: ' .. path, vim.log.levels.WARN)
    return nil
  end

  local cues, cur = {}, nil
  for i, line in ipairs(lines) do
    line = line:gsub('\r$', '')
    if i == 1 then line = line:gsub('^\239\187\191', '') end  -- UTF-8 BOM

    local h1, m1, s1, f1, h2, m2, s2, f2 = line:match(
      '(%d+):(%d+):(%d+)[,.](%d+)%s*%-%->%s*(%d+):(%d+):(%d+)[,.](%d+)')
    if h1 then
      cur = { start = timestamp(h1, m1, s1, f1), stop = timestamp(h2, m2, s2, f2), lines = {} }
      table.insert(cues, cur)
    elseif line:match('^%s*$') then
      cur = nil
    elseif cur then
      local text = clean(line)
      if text ~= '' then table.insert(cur.lines, text) end
    end
  end

  for _, c in ipairs(cues) do
    c.text  = table.concat(c.lines, ' ')
    c.lines = nil
  end
  table.sort(cues, function(a, b) return a.start < b.start end)
  return cues
end

--- Cue being displayed at time `t`, and the one after it.
---@return table|nil current, table|nil upcoming
function M.at(cues, t)
  if not cues or not t then return nil, nil end
  for i, c in ipairs(cues) do
    if t < c.start then return nil, c end
    if t < c.stop then return c, cues[i + 1] end
  end
  return nil, nil
end

return M
