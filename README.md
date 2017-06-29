# lua-lluv-rs232

## Usage
```Lua
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

port:open(function(self, err, data)
  if err then
    print("Port open error:", err)
    return self:close()
  end

  self:start_read(function(self, err, data)
    if err then
      print("Port read error:", err)
      return self:close()
    end
    io.write(data)
  end)

  port:write('AT\r\n')
end)

uv.run()
```
