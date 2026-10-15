-- nvimedia.nvim - mpv JSON IPC client
-- Talks to mpv's --input-ipc-server socket directly through libuv, so no
-- external tool (socat / nc) is needed, and mpv can report state back to us
-- (playback position, pause state, ...).

local M = {}

local uv = vim.uv or vim.loop

local RETRY_MS     = 100  -- mpv needs a moment to create its socket
local MAX_ATTEMPTS = 50   -- give up after ~5s

local Session = {}
Session.__index = Session

--- Open a session to the mpv instance listening on `path`.
--- Commands sent before the socket is ready are queued and flushed on connect.
---@param path string socket path
---@param on_event fun(msg: table) called (on the main loop) for each mpv event
function M.connect(path, on_event)
  local self = setmetatable({
    path     = path,
    on_event = on_event,
    pending  = {},
    buf      = '',
    closed   = false,
    attempts = 0,
  }, Session)
  self:_try_connect()
  return self
end

function Session:_try_connect()
  if self.closed then return end
  self.attempts = self.attempts + 1

  local pipe = uv.new_pipe(false)
  pipe:connect(self.path, function(err)
    if self.closed or err then
      pipe:close()
      if self.closed then return end
      if self.attempts >= MAX_ATTEMPTS then
        vim.schedule(function()
          vim.notify('[nvimedia] Could not connect to mpv IPC socket', vim.log.levels.WARN)
        end)
        return
      end
      self.timer = self.timer or uv.new_timer()
      self.timer:start(RETRY_MS, 0, function() self:_try_connect() end)
      return
    end

    self.pipe = pipe
    for _, line in ipairs(self.pending) do pipe:write(line) end
    self.pending = {}
    pipe:read_start(function(rerr, data)
      if rerr or not data then return end  -- EOF: mpv exited, job on_exit cleans up
      self:_on_data(data)
    end)
  end)
end

function Session:_on_data(data)
  self.buf = self.buf .. data
  local lines = {}
  while true do
    local nl = self.buf:find('\n', 1, true)
    if not nl then break end
    table.insert(lines, self.buf:sub(1, nl - 1))
    self.buf = self.buf:sub(nl + 1)
  end
  if #lines == 0 then return end

  vim.schedule(function()
    if self.closed then return end
    for _, line in ipairs(lines) do
      local ok, msg = pcall(vim.json.decode, line)
      if ok and type(msg) == 'table' and msg.event then self.on_event(msg) end
    end
  end)
end

--- Send a command, e.g. session:command({ 'set_property', 'pause', true })
---@param args any[]
function Session:command(args)
  if self.closed then return end
  local line = vim.json.encode({ command = args }) .. '\n'
  if self.pipe then
    self.pipe:write(line)
  else
    table.insert(self.pending, line)
  end
end

function Session:close()
  if self.closed then return end
  self.closed = true
  if self.timer and not self.timer:is_closing() then
    self.timer:stop()
    self.timer:close()
  end
  if self.pipe and not self.pipe:is_closing() then
    self.pipe:close()
  end
end

return M
