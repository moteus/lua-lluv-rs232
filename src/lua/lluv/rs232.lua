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
local function zmq_device_poller(pipe, port_name, port_opt)
  pipe:set_linger(1000)
  pipe:set_sndtimeo(1000)

  local LogLib = require "log"
  local rs232  = require "rs232"
  local zmq    = require "lzmq"

  local logger, log_writer do
    local base_formatter = require "log.formatter.concat".new('')

    local log_formatter = function(...)
      return string.format("[%s] %s", port_name, base_formatter(...))
    end

    log_writer = require "log.writer.stdout".new()

    logger = LogLib.new('none',
      function(...) return log_writer and log_writer(...) end,
      log_formatter
    )
  end

  local function escape(str)
    return (str
      :gsub("\r", "\\r")
      :gsub("\n", "\\n")
      :gsub("\t", "\\t")
      :gsub("[%z\001-\031]", function(ch)
        return string.format("\\%.3d", string.byte(ch))
      end))
  end

  local function dump(typ, data)
    return "[" .. port_name .. "] " .. typ .. " " .. escape(data)
  end

  local p, reading

  local function open_port()
    local p, e = rs232.port(port_name, port_opt)
    if not p then
      logger.error("Can not open serial port:", e)
      pipe:sendx('ERROR', 'RS232', tostring(e:no()))
      return
    end

    logger.info("serial port open: ", p)

    local buf = {}
    while true do
      local len, err = p:in_queue()
      if (len == 0) or (not len) then break end

      local ok, data = p:read(128)
      if data and #data > 0 then
        buf[#buf + 1] = data
      end
    end
    buf = table.concat(buf)

    logger.info_dump(dump, "serial port init data:", buf)

    pipe:sendx('OK', tostring(p), buf)

    return p
  end

  local function poll_serial()
    if not reading then return true end

    for i = 1, 64 do
      local len = p:in_queue()
      if (not len) or len == 0 then break end

      local data, err = p:read(len, 0)
      if data and #data > 0 then
        logger.trace_dump(dump, '<<', data)
        pipe:sendx('\0', data)
      end
    end
    return true
  end

  local API = {} do

    API[ "SET VERBOSE"    ] = function (level)
      if level then logger.set_lvl(level) end
      pipe:sendx('RES', 'OK')
      return true
    end

    API[ "SET LOG WRITER" ] = function (writer)
      if not writer then return end
      local loadstring = loadstring or load
      local err

      writer, err = loadstring(writer)
      if not writer then
        pipe:sendx('RES', 'LOG', tostring(err))
        return true
      end
      
      writer, err = writer()
      if not writer then
        pipe:sendx('RES', 'LOG', tostring(err))
        return true
      end

      pipe:sendx('RES', 'OK')
      log_writer = writer

      return true
    end

    API[ "TERM"           ] = function()
      pipe:sendx('RES', 'OK')
      return false
    end;

    API[ "STOP_READ"      ] = function()
      reading = false
      return true
    end;

    API[ "START_READ"     ] = function()
      reading = true
      return true
    end;

    API[ "FLUSH"          ] = function()
      local ok, err = p:flush()
      if not ok then
        pipe:sendx('RES', 'RS232', tostring(err:no()))
      else
        pipe:sendx('RES', 'OK')
      end
      return true
    end;

  end

  local function poll_socket()
    -- can return nil/flase/true
    local ok, err = pipe:poll(1)

    -- we get error
    if ok == nil then
      if err:no() == zmq.ETERM then return end
      if err:no() ~= zmq.EAGAIN then
        logger.fatal("ZMQ Unexpected poll error:", err)
        return
      end
    end

    if not ok then return true end

    local typ, msg, a, b, c, d = pipe:recvx(zmq.DONTWAIT)
    if not typ then
      if msg:no() ~= zmq.ETERM then
        logger.fatal("ZMQ Unexpected recv error:", err)
      end
      return
    end

    -- sent data to serial port
    if typ == '\0' then -- data
      logger.trace_dump(dump, '>>', msg)

      local n, err = p:write(msg)
      if n ~= #msg then
        logger.error('Write error:', tostring(err), ' data size:', tostring(#msg), ' written:', n)
      end

      return true

    -- command from actor
    elseif typ == 'CMD' then
      local api = API[msg]
      assert(api, msg)
      if not api(a, b, c, d) then return end
      return true
    end
  end

  p = open_port()
  if not p then return end

  local function main()
    while true do
      if not poll_serial() then break end
      if not poll_socket() then break end
    end
  end

  local ok, err = pcall(main)
  if ok then err = '' end

  logger.info("port close: ", err)

  pipe:sendx('TERM', tostring(err))
end

local zth   = require "lzmq.threads"
local uv    = require "lluv"
local ut    = require "lluv.utils"
uv.poll_zmq = require "lluv.poll_zmq"
local rs232 = require "rs232"

---------------------------------------------------------------
local Device = ut.class() do

function Device:__init(port_name, opt)
  local opt = opt or {
    baud         = rs232.RS232_BAUD_9600;
    data_bits    = rs232.RS232_DATA_8;
    parity       = rs232.RS232_PARITY_NONE;
    stop_bits    = rs232.RS232_STOP_1;
    flow_control = rs232.RS232_FLOW_OFF;
    rts          = rs232.RS232_RTS_ON;
  }

  self._port_name = port_name
  self._port_opt  = opt
  self._queue     = ut.Queue.new()
  self._buffer    = ut.Buffer.new()

  return self
end

function Device:close(cb)
  self:stop_read()
  if self._actor  then
    local actor, poller = self._actor, self._poller
    if self._actor:alive() then
      local timer

      self:_ioctl(function(...)
        actor:close()
        poller:close()
        timer:close()
        self._actor, self._poller = nil
        if cb then cb(...) cb = nil end
      end, 'TERM')

      timer = uv.timer():start(2000, function()
        actor:close()
        poller:close()
        timer:close()
        self._actor, self._poller = nil
        if cb then cb(self) cb = nil end
      end)

    end
  end
end

function Device:open(cb)
  if self._actor then return end

  self._actor = zth.xactor(
    zmq_device_poller,
    self._port_name,
    self._port_opt
  ):start()

  self._poller = uv.poll_zmq(self._actor)

  self._poller:start(function(handle, err, pipe)
    self._poller:stop()

    if err then
      self:close()
      return cb(self, err)
    end

    local typ, msg, data = self._actor:recvx()
    if not typ then
      self:close()
      return cb(self, msg)
    end

    if typ == 'OK' then
      assert(self._actor)
      self:_start()
      return cb(self, nil, msg, data)
    end

    if typ == 'ERROR' then
      self:close()
      local err = tonumber(data)
      if msg == 'RS232' then err = rs232.error(err) end
      return cb(self, err)
    end

    print('UNEXPECTED MESSAGE:', typ, msg, data)
    error('UNEXPECTED MESSAGE:' .. typ)
  end)
end

function Device:_do_read()
  if self._read_cb then
    local buf = self._buffer:read_all()
    if buf and #buf > 0 then
      self:_read_cb(nil, buf)
    end
  end

  if self._poll_error then
    local err = self._poll_error
    self._poll_error = nil
    if self._read_cb then
      self:_read_cb(err)
    end
  end

  self._has_read = false
end

function Device:_mark_read()
  if self._has_read then return end
  self._has_read = true
  uv.defer(self._do_read, self)
end

function Device:_start()
  self._poller:start(function(handle, err, pipe)
    if err then
      self._poll_error = err
      return self:_mark_read()
    end

    local typ, msg, data = self._actor:recvx()
    if not typ then
      self._poll_error = msg
      return self:_mark_read()
    end

    if typ == '\0' then
      self._buffer:append(msg)
      return self:_mark_read()
    end

    if typ == 'RES' then
      local cb = self._queue:pop()
      if cb then return cb(self, msg, data) end
    end

    if typ == 'TERM' then
      err = uv.error('LIBUV', uv.EOF)
      self._poll_error = err
      return self:_mark_read()
    end

  end)
end

function Device:start_read(cb)
  self._read_cb = cb
  self:_ioctl(nil, 'START_READ')
  return self:_mark_read()
end

function Device:stop_read()
  self._read_cb = nil
  self:_ioctl(nil, 'STOP_READ')
  return self
end

function Device:_write(typ, msg, cb)
  local ok, err = self._actor:sendx(typ, msg)
  if cb then
    uv.defer(cb, self, err)
    return self
  end
  if not ok then return nil, err end
  return self
end

function Device:write(...)
  return self:_write('\0', ...)
end

function Device:_ioctl(cb, cmd, ...)
  local ok, err = self._actor:sendx('CMD', cmd, ...)
  if not ok then
    if cb then
      uv.defer(cb, self, err)
      return self
    end
    return nil, err
  end

  self._queue:push(cb and cb or false)
  return self
end

function Device:set_log_level(level, cb)
  if level == false then level = 'none' end

  self:_ioctl(function(self, res, err)
    if not cb then return end
    if res ~= 'OK' then res = nil end
    cb(self, res, err)
  end, 'SET VERBOSE', level)
end

function Device:set_log_writer(writer, cb)
  assert(type(writer) == 'string')

  self:_ioctl(function(self, res, err)
    if not cb then return end
    if res ~= 'OK' then res = nil end
    cb(self, res, err)
  end, 'SET LOG WRITER', writer)
end

function Device:flush(cb)
  self:_ioctl(function(self, res, info)
    if not cb then return end
    if res == 'OK' then return cb(self) end
    local err = tonumber(info)
    if msg == 'RS232' then err = rs232.error(err) end
    return cb(self, err)
  end, 'FLUSH')
end

end
---------------------------------------------------------------

return setmetatable({},{
  __call = function(_, ...)
    return Device.new(...)
  end;
})
