------------------------------------------------------------------
--
--  Author: Alexey Melnichuk <alexeymelnichuck@gmail.com>
--
--  Copyright (C) 2014 Alexey Melnichuk <alexeymelnichuck@gmail.com>
--
--  Licensed according to the included 'LICENSE' document
--
--  This file is part of lua-lluv-rs232 library.
--
------------------------------------------------------------------

local uv = require "lluv"
uv.rs232 = require "lluv.rs232"
local ut = require "lluv.utils"

local function _check_resume(status, ...)
  if not status then return error(..., 3) end
  return ...
end

local function co_resume(...)
  return _check_resume(coroutine.resume(...))
end

local CoBase = ut.class() do

function CoBase:__init()
  self._co     = assert(coroutine.running())
  self._wait   = {
    read   = false;
    write  = false;
  }
  self._timer = assert(uv.timer():start(1000, function(tm)
    tm:stop()
    self:_resume(nil, "timeout")
  end):stop())

  return self
end

function CoBase:_resume(...)
  return co_resume(self._co, ...)
end

function CoBase:_yield(...)
  return coroutine.yield(...)
end

function CoBase:_unset_wait()
  for k in pairs(self._wait) do self._wait[k] = false end
end

function CoBase:_waiting(op)
  if op then
    assert(nil ~= self._wait[op])
    return not not self._wait[op]
  end

  for k, v in pairs(self._wait) do
    if v then return true end
  end
end

function CoBase:_start(op, timeout)
  if timeout then
    self._timer:again(timeout)
  end

  assert(not self:_waiting())

  assert(self._wait[op] == false, op)
  self._wait[op] = true
end

function CoBase:_stop(op)
  if self._timer then
    self._timer:stop()
  end
  self:_unset_wait(op)
end

function CoBase:attach(co)
  assert(not self:_waiting())
  self._co = co or coroutine.running()
  return self
end

end

local CoRs232 = ut.class(CoBase) do

function CoRs232:__init(...)
  assert(CoRs232.__base.__init(self))
  self._buf = ut.Buffer.new()
  self._wait.open   = false
  self._wait.close  = false
  self._port = uv.rs232(...)
  return self
end

function CoRs232:_on_io_error(err)
  self._err = err

  self._port:stop_read()

  self._port:close(function()
    if self:_waiting() then
      self:_resume(nil, err)
    end
  end)

  self._timer:close()
  self._port, self._timer = nil
end

function CoRs232:_start_read()
  self._port:start_read(function(cli, err, data)
    if err then return self:_on_io_error(err) end

    if data then self._buf:append(data) end

    if self:_waiting("read") then return self:_resume(true) end
  end)
  return self
end

local function read_most(buffer, n)
  n = math.floor(n)

  local size, t = 0, {}
  while true do
    local chunk = buffer:read_some()

    if not chunk then
      return table.concat(t)
    end

    if (size + #chunk) >= n then
      assert(n > size)
      local pos = n - size
      local data = string.sub(chunk, 1, pos)
      if pos < #chunk then
        buffer:prepend(string.sub(chunk, pos + 1))
      end

      t[#t + 1] = data
      return table.concat(t)
    end

    t[#t + 1] = chunk
    size = size + #chunk
  end
end

function CoRs232:read(len, timeout, forced)
  assert(type(len) == 'number')
  if not self._port then return nil, self._err end

  self:_start("read", timeout)

  while true do
    if not self._buf:empty() then
      if forced then
        local msg = self._buf:read_n(len)
        if msg then
          self:_stop("read")
          return msg
        end
      else
        self:_stop("read")
        return read_most(self._buf, len)
      end
    end

    local ok, err = self:_yield()
    if not ok then
      self:_stop("read")
      if err == 'timeout' then
        return read_most(self._buf, len)
      end
      return nil, err
    end
  end
end

function CoRs232:write(data)
  assert(type(data) == 'string')
  if not self._port then return nil, self._err end

  local terminated
  self:_start("write")
  self._port:write(data, function(cli, err)
    if terminated then return end
    if err then return self:_on_io_error(err) end
    return self:_resume(true)
  end)

  local ok, err = self:_yield()
  terminated = true
  self:_stop("write")

  if not ok then
    return nil, self._err
  end

  return self
end

function CoRs232:open()
  local terminated
  self:_start("open")

  self._port:open(function(cli, err, data)
    if terminated then return end
    if err then return self:_on_io_error(err) end
    return self:_resume(true, data)
  end)

  local ok, data = self:_yield()
  terminated = true
  self:_stop("open")

  if not ok then
    return nil, self._err
  end

  self:_start_read()

  return self, data
end

function CoRs232:close()
  if not self._port then return true end

  local terminated
  self:_start("close")

  self._port:close(function(cli, err, data)
    if terminated then return end
    if err then return self:_on_io_error(err) end
    return self:_resume(true)
  end)

  local ok, data = self:_yield()
  terminated = true
  self:_stop("close")

  self._timer:close()
  self._timer, self._port = nil

  return true
end

function CoRs232:in_queue_clear()
  while true do
    local d = self:read(1024, 100)
    if not d or #d == 0 then break end
  end
end

end

return {
  port = CoRs232.new;
}
