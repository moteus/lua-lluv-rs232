package.path = "../src/lua/?.lua;" .. package.path

local uv = require "lluv"
uv.rs232 = require "lluv.rs232"

local port = uv.rs232('COM3',{
  baud         = '_9600';
  data_bits    = '_8';
  parity       = 'NONE';
  stop_bits    = '_1';
  flow_control = 'OFF';
  rts          = 'ON';
})

port:set_log_level('trace')

port:open(function(self, err, info, data)
  if err then
    print("Port open error:", err)
    return self:close()
  end

  print("Port:", info)
  print("Pending data:", data)

  local buffer = ''
  self:start_read(function(self, err, data)
    if err then
      print("Port read error:", err)
      return self:close()
    end

    io.write(data)

    buffer = buffer .. data
    if buffer:find('\r\nOK\r\n', nil, true) then
      port:close(function()
        print("Port closed")
      end)
    end

  end)

  port:write('AT\r\n')
end)

uv.run()
