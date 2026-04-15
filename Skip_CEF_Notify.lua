script_name('Skip CEF Notify')
script_author('Charlie_Deep t.me/rakbotik')
script_version('1.00')

local enabled = true
local IFACE = 87
local SUB   = 0
local closing = false
local function u8b(b)
  if type(b) ~= 'number' then return 0 end
  return b < 0 and b + 256 or b
end
local function bs_read_raw(bs)
  local total = raknetBitStreamGetNumberOfBytesUsed(bs) or 0
  raknetBitStreamResetReadPointer(bs)
  local t = {}
  for i = 1, total do
    local b = raknetBitStreamReadInt8(bs)
    if b == nil then break end
    t[i] = u8b(b)
  end
  raknetBitStreamResetReadPointer(bs)
  return t
end
local function send_close()
  local bs = raknetNewBitStream()
  raknetBitStreamWriteInt8(bs, 220)
  raknetBitStreamWriteInt8(bs, 63)
  raknetBitStreamWriteInt8(bs, IFACE)
  raknetBitStreamWriteInt32(bs, 0)
  raknetBitStreamWriteInt32(bs, SUB)
  raknetBitStreamWriteInt16(bs, 2)
  raknetBitStreamWriteInt8(bs, 0)
  raknetBitStreamWriteInt8(bs, 123)
  raknetBitStreamWriteInt8(bs, 125)
  raknetSendBitStreamEx(bs, 7, 0, 0)
  raknetDeleteBitStream(bs)
end
function onReceivePacket(id, bs)
  if not enabled or closing then return end
  if id ~= 220 then return end
  local raw = bs_read_raw(bs)
  if #raw < 4 then return end
  if raw[2] ~= 84 then return end
  if raw[3] ~= IFACE then return end
  if raw[4] ~= SUB then return end
  closing = true
  lua_thread.create(function()
    for i = 1, 10 do
      send_close()
      wait(50)
    end
    closing = false
  end)
end
function main()
  if not isSampLoaded() or not isSampfuncsLoaded() then return end
  while not isSampAvailable() do wait(50) end
  while true do wait(0) end
end
