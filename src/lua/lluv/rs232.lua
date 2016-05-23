------------------------------------------------------------------
--
--  Author: Alexey Melnichuk <alexeymelnichuck@gmail.com>
--
--  Copyright (C) 2014-2016 Alexey Melnichuk <alexeymelnichuck@gmail.com>
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

  local OK       = '\0'
  local RES_TERM = '\1'
  local RES_DATA = '\2'
  local RES_CMD  = '\3'
  local REQ_DATA = '\4'
  local REQ_CMD  = '\5'

  local LOG, log_writer do
    local base_formatter = require "log.formatter.concat".new('')

    local log_formatter = function(...)
      return string.format("[%s] %s", port_name, base_formatter(...))
    end

    log_writer = require "log.writer.stdout".new()

    LOG = LogLib.new('none',
      function(...) return log_writer and log_writer(...) end,
      log_formatter
    )
  end

  local function escape(str)
    return (str
      :gsub("\r", "\\r")
      :gsub("\n", "\\n")
      :gsub("\t", "\\t")
      :gsub("[%z\001-\031\127-\255]", function(ch)
        return string.format("\\%.3d", string.byte(ch))
      end))
  end

  local function dump(typ, data)
    return "[" .. port_name .. "] " .. typ .. " " .. escape(data)
  end

  local p, reading

  local function open_port()
    local p, e = rs232.port(port_name, port_opt):open()
    if not p then
      LOG.error("Can not open serial port:", e)
      pipe:sendx(RES_CMD, 'RS232', tostring(e:no()))
      return
    end

    LOG.info("serial port open: ", p)

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

    LOG.info_dump(dump, "serial port init data:", buf)

    pipe:sendx(RES_CMD, OK, tostring(p), buf)

    return p
  end

  local function poll_serial()
    if not reading then return true end

    local data, err = p:read(128, 100)
    if data and #data > 0 then
      LOG.trace_dump(dump, '<<', data)
      pipe:sendx(RES_DATA, data)
    else return true end

    for i = 1, 64 do
      local len = p:in_queue()
      if (not len) or len == 0 then break end

      local data, err = p:read(len, 0)
      if data and #data > 0 then
        LOG.trace_dump(dump, '<<', data)
        pipe:sendx(RES_DATA, data)
      end
    end
    return true
  end

  local API = {} do

    API[ "SET VERBOSE"    ] = function (level)
      if level then LOG.set_lvl(level) end
      pipe:sendx(RES_CMD, OK)
      return true
    end

    API[ "SET LOG WRITER" ] = function (writer)
      if not writer then return end
      local loadstring = loadstring or load
      local err

      writer, err = loadstring(writer)
      if not writer then
        pipe:sendx(RES_CMD, 'LOG', tostring(err))
        return true
      end
      
      writer, err = writer()
      if not writer then
        pipe:sendx(RES_CMD, 'LOG', tostring(err))
        return true
      end

      pipe:sendx(RES_CMD, OK)
      log_writer = writer

      return true
    end

    API[ "OPEN"           ] = function()
      if not p then
        p = open_port()
      else
        pipe:sendx(RES_CMD, OK)
      end

      return true
    end;

    API[ "TERM"           ] = function()
      pipe:sendx(RES_CMD, OK)
      return false
    end;

    API[ "STOP_READ"      ] = function()
      if not p then
        pipe:sendx(RES_CMD, 'RS232', rs232.RS232_ERR_PORT_CLOSED)
      else
        pipe:sendx(RES_CMD, OK)
        reading = false
      end
      return true
    end;

    API[ "START_READ"     ] = function()
      if not p then
        pipe:sendx(RES_CMD, 'RS232', rs232.RS232_ERR_PORT_CLOSED)
      else
        pipe:sendx(RES_CMD, OK)
        reading = true
      end
      return true
    end;

    API[ "FLUSH"          ] = function()
      if not p then
        pipe:sendx(RES_CMD, 'RS232', rs232.RS232_ERR_PORT_CLOSED)
      else
        local ok, err = p:flush()
        if not ok then
          pipe:sendx(RES_CMD, 'RS232', tostring(err:no()))
        else
          pipe:sendx(RES_CMD, OK)
        end
      end
      return true
    end;

  end

  local function poll_socket()
    -- can return nil/flase/true
    local ok, err = pipe:poll(reading and 1 or 1000)

    -- we get error
    if ok == nil then
      if err:no() == zmq.ETERM then return end
      if err:no() ~= zmq.EAGAIN then
        LOG.fatal("ZMQ Unexpected poll error:", err)
        return nil, err
      end
    end

    if not ok then return true end

    local typ, msg, a, b, c, d = pipe:recvx(zmq.DONTWAIT)
    if not typ then
      if msg:no() ~= zmq.ETERM then
        LOG.fatal("ZMQ Unexpected recv error:", msg)
      else msg = nil end
      return nil, msg
    end

    -- sent data to serial port
    if typ == REQ_DATA then
      LOG.trace_dump(dump, '>>', msg)

      local n, err = p:write(msg)
      if n ~= #msg then
        LOG.error('Write error:', tostring(err), ' data size:', tostring(#msg), ' written:', n)
      end

      return true

    -- command from actor
    elseif typ == REQ_CMD then
      local api = API[msg]
      assert(api, msg)
      return api(a, b, c, d)
    end

  end

  local function main()
    while true do
      local ok, err = poll_serial()
      if not ok then return nil, err end

      local ok, err = poll_socket()
      if not ok then return nil, err end
    end
  end

  local ok, err, err2 = pcall(main)
  if ok then err = err2 or '' end

  if err and #err ~= 0 then
    LOG.fatal("abnormal close thread:", err)
  else
    LOG.info("port close")
  end

  pipe:sendx(RES_TERM, tostring(err))
end

local OK       = '\0'
local RES_TERM = '\1'
local RES_DATA = '\2'
local RES_CMD  = '\3'
local REQ_DATA = '\4'
local REQ_CMD  = '\5'

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

  self._port_name  = port_name
  self._port_opt   = opt
  self._queue      = ut.Queue.new()
  self._buffer     = ut.Buffer.new()
  self._terminated = false
  self._actor      = zth.xactor(
    zmq_device_poller,
    self._port_name,
    self._port_opt
  ):start()
  self._poller     = uv.poll_zmq(self._actor)

  return self:_start()
end

function Device:close(cb)
  self:stop_read()

  if self._actor  then
    if self._terminated then
      self._actor:close()
      self._poller:close(function()
        if cb then cb(self) end
      end)
      self._actor, self._poller = nil
      return
    end

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

local function decode_cmd_reponse(res, info)
  if res == OK then return nil, info end
  if res == 'RS232' then return rs232.error(tonumber(info)) end
  return info
end

function Device:open(cb)
  self:_ioctl(function(self, res, info)
    if not cb then return end
    cb(self, decode_cmd_reponse(res, info))
  end, 'OPEN')

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

    if typ == RES_DATA then
      self._buffer:append(msg)
      return self:_mark_read()
    end

    if typ == RES_CMD then
      local cb = self._queue:pop()
      if cb then cb(self, msg, data) end
      return
    end

    if typ == RES_TERM then
      err = uv.error('LIBUV', uv.EOF)
      self._poll_error = err
      self._terminated = true
      return self:_mark_read()
    end

  end)

  return self
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
  return self:_write(REQ_DATA, ...)
end

function Device:_ioctl(cb, cmd, ...)
  local ok, err = self._actor:sendx(REQ_CMD, cmd, ...)
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

  self:_ioctl(function(self, res, info)
    if not cb then return end
    cb(self, decode_cmd_reponse(res, info))
  end, 'SET VERBOSE', level)
end

function Device:set_log_writer(writer, cb)
  assert(type(writer) == 'string')

  self:_ioctl(function(self, res, info)
    if not cb then return end
    cb(self, decode_cmd_reponse(res, info))
  end, 'SET LOG WRITER', writer)
end

function Device:flush(cb)
  self:_ioctl(function(self, res, info)
    if not cb then return end
    cb(self, decode_cmd_reponse(res, info))
  end, 'FLUSH')
end

end
---------------------------------------------------------------

return setmetatable({
  _NAME      = "lluv-rs232";
  _VERSION   = "0.1.0";
  _COPYRIGHT = "Copyright (C) 2014-2016 Alexey Melnichuk";
  _LICENSE   = "MIT";
},{
  __call = function(_, ...)
    return Device.new(...)
  end;
})
