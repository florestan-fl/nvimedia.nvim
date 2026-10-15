-- nvimedia.nvim - SRT subtitle parser

local M = {}

--- Convert SRT timestamp string to seconds (float)
--- Format: HH:MM:SS,mmm  or  HH:MM:SS.mmm
---@param ts string
---@return number seconds
local function ts_to_sec(ts)
  local h, m, s, ms = ts:match('(%d+):(%d+):(%d+)[,.](%d+)')
  if not h then return 0 end
  return tonumber(h) * 3600
       + tonumber(m) * 60
       + tonumber(s)
       + tonumber(ms) / 1000
end

--- Parse an SRT file into a list of cue entries.
--- Each entry: { start = <seconds>, stop = <seconds>, text = <string> }
--- Multi-line cue text is joined with a newline.
---@param path string absolute path to .srt file
---@return table[] cues, or empty list on error
function M.parse(path)
  local f = io.open(path, 'r')
  if not f then
    vim.notify('[nvimedia] Cannot open SRT file: ' .. path, vim.log.levels.WARN)
    return {}
  end
  local content = f:read('*a')
  f:close()

  -- Normalise line endings
  content = content:gsub('\r\n', '\n'):gsub('\r', '\n')

  local cues = {}

  -- Split into blocks by blank line
  for block in (content .. '\n\n'):gmatch('(.-)\n\n') do
    block = block:match('^%s*(.-)%s*$')  -- trim
    if block ~= '' then
      local lines = {}
      for line in (block .. '\n'):gmatch('([^\n]*)\n') do
        table.insert(lines, line)
      end

      -- Line 1: sequence number (we ignore it)
      -- Line 2: timestamps  "00:00:01,000 --> 00:00:04,500"
      -- Line 3+: text
      if #lines >= 2 then
        local t_start, t_stop = lines[2]:match('([%d:,%.]+)%s*%-%->%s*([%d:,%.]+)')
        if t_start and t_stop then
          local text_lines = {}
          for i = 3, #lines do
            -- Strip basic HTML tags used in some SRT files (<i>, <b>, etc.)
            -- and ASS override tags ({\an8}, ...)
            local cleaned = lines[i]:gsub('<[^>]+>', ''):gsub('{\\[^}]*}', '')
            if cleaned ~= '' then
              table.insert(text_lines, cleaned)
            end
          end
          if #text_lines > 0 then
            table.insert(cues, {
              start = ts_to_sec(t_start),
              stop  = ts_to_sec(t_stop),
              text  = table.concat(text_lines, '\n'),
            })
          end
        end
      end
    end
  end

  -- Sort by start time (most SRTs are already sorted, but just in case)
  table.sort(cues, function(a, b) return a.start < b.start end)
  return cues
end

--- Binary-search for the active cue at a given playback position.
--- Returns the cue table or nil if nothing is active.
---@param cues table[]
---@param pos number  playback position in seconds
---@param advance number  how many seconds early to show the cue (default 0)
---@return table|nil
function M.active_cue(cues, pos, advance)
  advance = advance or 0
  local t = pos + advance
  -- Linear scan is fine for typical SRT sizes (<2000 cues)
  -- For large files a binary search would be better but isn't needed here
  for _, cue in ipairs(cues) do
    if t >= cue.start and pos < cue.stop then
      return cue
    end
  end
  return nil
end

return M
