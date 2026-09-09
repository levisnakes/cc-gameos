--[[ ccmock.lua -- A headless mock of the CC:Tweaked API, accurate enough to
     run GameOS end to end: buffered terminals, windows, palettes, the event
     loop, a virtual clock, a read-only filesystem and a recording speaker. ]]

local M = {}

----------------------------------------------------------------- bit32 shim
bit32 = {}
local function tobit(x) x = math.floor(x) % 4294967296 return x end
function bit32.band(a, b) local r, c = 0, 1 a, b = tobit(a), tobit(b)
  for _ = 1, 32 do if a % 2 == 1 and b % 2 == 1 then r = r + c end a = math.floor(a / 2) b = math.floor(b / 2) c = c * 2 end return r end
function bit32.bor(a, b) local r, c = 0, 1 a, b = tobit(a), tobit(b)
  for _ = 1, 32 do if a % 2 == 1 or b % 2 == 1 then r = r + c end a = math.floor(a / 2) b = math.floor(b / 2) c = c * 2 end return r end
function bit32.bxor(a, b) local r, c = 0, 1 a, b = tobit(a), tobit(b)
  for _ = 1, 32 do if (a % 2) ~= (b % 2) then r = r + c end a = math.floor(a / 2) b = math.floor(b / 2) c = c * 2 end return r end
function bit32.lshift(a, n) return tobit(a * 2 ^ n) end
function bit32.rshift(a, n) return math.floor(tobit(a) / 2 ^ n) end

-------------------------------------------------------------------- colours
colors = {
  white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32,
  pink = 64, gray = 128, grey = 128, lightGray = 256, lightGrey = 256,
  cyan = 512, purple = 1024, blue = 2048, brown = 4096, green = 8192,
  red = 16384, black = 32768,
}
local HEX = "0123456789abcdef"
local ORDER = {}
do local c = 1 for i = 0, 15 do ORDER[i + 1] = c c = c * 2 end end
function colors.toBlit(c) for i = 1, 16 do if ORDER[i] == c then return HEX:sub(i, i) end end return "0" end
function colors.fromBlit(ch) local i = HEX:find(ch, 1, true) return i and ORDER[i] or nil end
function colors.combine(...) local r = 0 for i = 1, select("#", ...) do r = bit32.bor(r, (select(i, ...))) end return r end
function colors.subtract(a, ...) for i = 1, select("#", ...) do a = bit32.band(a, 65535 - (select(i, ...))) end return a end
function colors.test(a, b) return bit32.band(a, b) == b end
function colors.packRGB(r, g, b) return math.floor(r * 255) * 65536 + math.floor(g * 255) * 256 + math.floor(b * 255) end
function colors.unpackRGB(v) return math.floor(v / 65536) % 256 / 255, math.floor(v / 256) % 256 / 255, v % 256 / 255 end
colours = setmetatable({ grey = colors.gray, lightGrey = colors.lightGray }, { __index = colors })

local DEFAULT_PALETTE = {
  [colors.white] = 0xF0F0F0, [colors.orange] = 0xF2B233, [colors.magenta] = 0xE57FD8,
  [colors.lightBlue] = 0x99B2F2, [colors.yellow] = 0xDEDE6C, [colors.lime] = 0x7FCC19,
  [colors.pink] = 0xF2B2CC, [colors.gray] = 0x4C4C4C, [colors.lightGray] = 0x999999,
  [colors.cyan] = 0x4C99B2, [colors.purple] = 0xB266E5, [colors.blue] = 0x3366CC,
  [colors.brown] = 0x7F664C, [colors.green] = 0x57A64E, [colors.red] = 0xCC4C4C,
  [colors.black] = 0x111111,
}

------------------------------------------------------------------------ keys
keys = {
  space = 32, apostrophe = 39, comma = 44, minus = 45, period = 46, slash = 47,
  zero = 48, one = 49, two = 50, three = 51, four = 52, five = 53, six = 54,
  seven = 55, eight = 56, nine = 57, semicolon = 59, equals = 61,
  leftBracket = 91, backslash = 92, rightBracket = 93, grave = 96,
  enter = 257, tab = 258, backspace = 259, insert = 260, delete = 261,
  right = 262, left = 263, down = 264, up = 265, pageUp = 266, pageDown = 267,
  home = 268, ["end"] = 269, capsLock = 280, scrollLock = 281, numLock = 282,
  printScreen = 283, pause = 284,
  numPad0 = 320, numPad1 = 321, numPad2 = 322, numPad3 = 323, numPad4 = 324,
  numPad5 = 325, numPad6 = 326, numPad7 = 327, numPad8 = 328, numPad9 = 329,
  numPadDecimal = 330, numPadDivide = 331, numPadMultiply = 332,
  numPadSubtract = 333, numPadAdd = 334, numPadEnter = 335, numPadEqual = 336,
  leftShift = 340, leftCtrl = 341, leftAlt = 342, leftSuper = 343,
  rightShift = 344, rightCtrl = 345, rightAlt = 346, rightSuper = 347, menu = 348,
}
do
  for i = 0, 25 do keys[string.char(97 + i)] = 65 + i end
  for i = 1, 12 do keys["f" .. i] = 289 + i end
  local names = {}
  for k, v in pairs(keys) do if type(v) == "number" then names[v] = k end end
  keys.getName = function(code) return names[code] end
end

-------------------------------------------------------------------- terminal
local function newBuffer(w, h)
  local b = { w = w, h = h, ch = {}, fg = {}, bg = {} }
  for y = 1, h do
    local cr, fr, br = {}, {}, {}
    for x = 1, w do cr[x], fr[x], br[x] = " ", "0", "f" end
    b.ch[y], b.fg[y], b.bg[y] = cr, fr, br
  end
  return b
end

local function makeTerm(w, h, isColour)
  local t = {}
  local buf = newBuffer(w, h)
  local cx, cy, fg, bg, blink = 1, 1, colors.white, colors.black, false
  local pal = {}
  for k, v in pairs(DEFAULT_PALETTE) do pal[k] = v end
  t.__buffer = buf
  t.__palette = pal

  local function put(x, y, char, f, b)
    if y < 1 or y > buf.h or x < 1 or x > buf.w then return end
    buf.ch[y][x], buf.fg[y][x], buf.bg[y][x] = char, f, b
  end

  function t.write(text)
    text = tostring(text)
    local f, b = colors.toBlit(fg), colors.toBlit(bg)
    for i = 1, #text do put(cx + i - 1, cy, text:sub(i, i), f, b) end
    cx = cx + #text
  end
  function t.blit(text, tf, tb)
    if type(text) ~= "string" or type(tf) ~= "string" or type(tb) ~= "string" then
      error("bad argument to blit (string expected)", 2)
    end
    if #text ~= #tf or #text ~= #tb then error("Arguments must be the same length", 2) end
    for i = 1, #text do put(cx + i - 1, cy, text:sub(i, i), tf:sub(i, i), tb:sub(i, i)) end
    cx = cx + #text
  end
  function t.clear()
    local b = colors.toBlit(bg)
    for y = 1, buf.h do for x = 1, buf.w do buf.ch[y][x], buf.fg[y][x], buf.bg[y][x] = " ", "0", b end end
  end
  function t.clearLine()
    local b = colors.toBlit(bg)
    if cy >= 1 and cy <= buf.h then
      for x = 1, buf.w do buf.ch[cy][x], buf.fg[cy][x], buf.bg[cy][x] = " ", "0", b end
    end
  end
  function t.scroll(n)
    local nb = newBuffer(buf.w, buf.h)
    local b = colors.toBlit(bg)
    for y = 1, buf.h do
      local sy = y + n
      for x = 1, buf.w do
        if sy >= 1 and sy <= buf.h then
          nb.ch[y][x], nb.fg[y][x], nb.bg[y][x] = buf.ch[sy][x], buf.fg[sy][x], buf.bg[sy][x]
        else
          nb.ch[y][x], nb.fg[y][x], nb.bg[y][x] = " ", "0", b
        end
      end
    end
    buf.ch, buf.fg, buf.bg = nb.ch, nb.fg, nb.bg
  end
  function t.getSize() return buf.w, buf.h end
  function t.setCursorPos(x, y) cx, cy = math.floor(x), math.floor(y) end
  function t.getCursorPos() return cx, cy end
  function t.setCursorBlink(v) blink = v end
  function t.getCursorBlink() return blink end
  function t.isColor() return isColour end
  function t.setTextColor(c) fg = c end
  function t.setBackgroundColor(c) bg = c end
  function t.getTextColor() return fg end
  function t.getBackgroundColor() return bg end
  function t.setPaletteColor(c, r, g, b)
    if g then pal[c] = colors.packRGB(r, g, b) else pal[c] = r end
  end
  function t.getPaletteColor(c) return colors.unpackRGB(pal[c] or 0) end
  function t.nativePaletteColor(c) return colors.unpackRGB(DEFAULT_PALETTE[c] or 0) end
  t.isColour = t.isColor
  t.setTextColour, t.setBackgroundColour = t.setTextColor, t.setBackgroundColor
  t.getTextColour, t.getBackgroundColour = t.getTextColor, t.getBackgroundColor
  t.setPaletteColour, t.getPaletteColour = t.setPaletteColor, t.getPaletteColor
  t.nativePaletteColour = t.nativePaletteColor
  return t
end

local native = makeTerm(51, 19, true)
local redirectTarget = native

term = {}
for _, name in ipairs({ "write", "blit", "clear", "clearLine", "scroll", "getSize",
  "setCursorPos", "getCursorPos", "setCursorBlink", "getCursorBlink", "isColor",
  "isColour", "setTextColor", "setTextColour", "setBackgroundColor",
  "setBackgroundColour", "getTextColor", "getTextColour", "getBackgroundColor",
  "getBackgroundColour", "setPaletteColor", "setPaletteColour", "getPaletteColor",
  "getPaletteColour" }) do
  term[name] = function(...) return redirectTarget[name](...) end
end
function term.redirect(t) local prev = redirectTarget redirectTarget = t return prev end
function term.current() return redirectTarget end
function term.native() return native end
function term.nativePaletteColor(c) return native.nativePaletteColor(c) end
term.nativePaletteColour = term.nativePaletteColor
M.native = native

------------------------------------------------------------ console output
local function rawWrite(text)
  text = tostring(text)
  local w, h = redirectTarget.getSize()
  local x, y = redirectTarget.getCursorPos()
  while #text > 0 do
    local room = w - x + 1
    if room <= 0 then
      x = 1
      y = y + 1
      room = w
    end
    if y > h then
      redirectTarget.scroll(1)
      y = h
    end
    redirectTarget.setCursorPos(x, y)
    local chunk = text:sub(1, room)
    local nl = chunk:find("\n", 1, true)
    if nl then chunk = chunk:sub(1, nl - 1) end
    redirectTarget.write(chunk)
    text = text:sub(#chunk + 1)
    if text:sub(1, 1) == "\n" then
      text = text:sub(2)
      x = 1
      y = y + 1
    else
      x = x + #chunk
    end
  end
  redirectTarget.setCursorPos(x, y)
end

function write(text) rawWrite(text) end
function print(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  rawWrite(table.concat(parts, " ") .. "\n")
end
function printError(...)
  local prev = redirectTarget.getTextColor()
  redirectTarget.setTextColor(colors.red)
  print(...)
  redirectTarget.setTextColor(prev)
end
function read() return "" end

--------------------------------------------------------------------- window
window = {}
function window.create(parent, px, py, w, h, visible)
  local win = makeTerm(w, h, parent.isColor())
  local buf = win.__buffer
  local visibleFlag = visible ~= false
  local baseWrite, baseBlit = win.write, win.blit
  local baseClear, baseClearLine, baseScroll = win.clear, win.clearLine, win.scroll

  local function flush()
    if not visibleFlag then return end
    for y = 1, h do
      parent.setCursorPos(px, py + y - 1)
      parent.blit(table.concat(buf.ch[y]), table.concat(buf.fg[y]), table.concat(buf.bg[y]))
    end
  end
  win.write = function(...) baseWrite(...) flush() end
  win.blit = function(...) baseBlit(...) flush() end
  win.clear = function(...) baseClear(...) flush() end
  win.clearLine = function(...) baseClearLine(...) flush() end
  win.scroll = function(...) baseScroll(...) flush() end
  function win.setVisible(v) local was = visibleFlag visibleFlag = v if v and not was then flush() end end
  function win.isVisible() return visibleFlag end
  function win.redraw() flush() end
  function win.restoreCursor() end
  function win.getPosition() return px, py end
  function win.reposition(nx, ny) px, py = nx, ny flush() end
  local setPal = win.setPaletteColor
  win.setPaletteColor = function(...) setPal(...) parent.setPaletteColor(...) end
  win.setPaletteColour = win.setPaletteColor
  function win.getLine(y)
    return table.concat(buf.ch[y]), table.concat(buf.fg[y]), table.concat(buf.bg[y])
  end
  return win
end

------------------------------------------------------------- clock & events
local vclock = 0
local timers, nextTimer = {}, 1
local queue = {}
M.frame = 0
M.hooks = {}
M.eventBudget = 2000000

function M.now() return vclock end
--- Push the virtual clock forward, for tests that need to watch a timeout
--- expire without queueing hundreds of timer events.
function M.advance(seconds) vclock = vclock + seconds end
function M.push(...) queue[#queue + 1] = { ... } end

os = os or {}
function os.clock() return vclock end
function os.time() return (vclock / 60) % 24 end
function os.day() return math.floor(vclock / 1440) end
function os.epoch() return 1735689600000 + math.floor(vclock * 1000) end
function os.getComputerID() return 7 end
M.label = "Workshop"
function os.getComputerLabel() return M.label end
function os.setComputerLabel(v) M.label = v end
function os.getComputerLabel() return "GAMEOS" end
function os.setComputerLabel() end
function os.startTimer(t)
  local id = nextTimer
  nextTimer = nextTimer + 1
  local d = math.max(tonumber(t) or 0, 0)
  d = math.ceil(d / 0.05) * 0.05
  if d < 0.05 then d = 0.05 end
  timers[id] = vclock + d
  return id
end
function os.cancelTimer(id) timers[id] = nil end
function os.queueEvent(...) M.push(...) end

local function advance()
  local bestId, bestT
  for id, t in pairs(timers) do
    if not bestT or t < bestT or (t == bestT and id < bestId) then bestId, bestT = id, t end
  end
  if not bestId then error("MOCK: deadlock -- no queued events and no pending timers", 0) end
  timers[bestId] = nil
  if bestT > vclock then vclock = bestT end
  M.frame = M.frame + 1
  if M.hooks.onTimer then M.hooks.onTimer(M.frame) end
  return { "timer", bestId }
end

function os.pullEventRaw(filter)
  while true do
    M.eventBudget = M.eventBudget - 1
    if M.eventBudget <= 0 then error("MOCK: event budget exhausted", 0) end
    local ev
    if #queue > 0 then ev = table.remove(queue, 1) else ev = advance() end
    if filter == nil or ev[1] == filter then return table.unpack(ev) end
  end
end
function os.pullEvent(filter)
  local ev = { os.pullEventRaw(filter) }
  if ev[1] == "terminate" then error("Terminated", 0) end
  return table.unpack(ev)
end
function os.sleep(t)
  local id = os.startTimer(t)
  while true do
    local e, a = os.pullEvent("timer")
    if a == id then break end
  end
end
sleep = os.sleep
function os.shutdown() error("MOCK_SHUTDOWN", 0) end
function os.reboot() error("MOCK_REBOOT", 0) end

------------------------------------------------------------------ filesystem
local files = {}
function M.mount(map) for k, v in pairs(map) do files[k] = v end end
local function norm(p)
  p = tostring(p):gsub("\\", "/")
  local parts = {}
  for seg in p:gmatch("[^/]+") do
    if seg == ".." then table.remove(parts) elseif seg ~= "." then parts[#parts + 1] = seg end
  end
  return table.concat(parts, "/")
end
fs = {}
function fs.combine(a, b, ...)
  local r = norm(a .. "/" .. (b or ""))
  local extra = { ... }
  for i = 1, #extra do r = norm(r .. "/" .. extra[i]) end
  return r
end
function fs.exists(p)
  p = norm(p)
  if p == "" or files[p] ~= nil then return true end
  for k in pairs(files) do if k:sub(1, #p + 1) == p .. "/" then return true end end
  return false
end
function fs.isDir(p)
  p = norm(p)
  if files[p] ~= nil then return false end
  if p == "" then return true end
  for k in pairs(files) do if k:sub(1, #p + 1) == p .. "/" then return true end end
  return false
end
function fs.getName(p) p = norm(p) return p:match("[^/]+$") or p end
function fs.getDir(p) p = norm(p) return p:match("^(.*)/[^/]+$") or "" end
function fs.list(p)
  p = norm(p)
  local seen, out = {}, {}
  local prefix = (p == "" and "" or p .. "/")
  for k in pairs(files) do
    if k:sub(1, #prefix) == prefix then
      local head = k:sub(#prefix + 1):match("^[^/]+")
      if head and not seen[head] then seen[head] = true out[#out + 1] = head end
    end
  end
  table.sort(out)
  return out
end
function fs.makeDir() end
function fs.delete(p) files[norm(p)] = nil end
function fs.getSize(p) local d = files[norm(p)] return d and #d or 0 end
function fs.open(p, mode)
  p = norm(p)
  if mode == "r" or mode == "rb" then
    local data = files[p]
    if not data then return nil, "No such file" end
    local pos = 1
    local h = {}
    function h.readAll()
      if pos > #data then return nil end
      local s = data:sub(pos) pos = #data + 1 return s
    end
    function h.readLine()
      if pos > #data then return nil end
      local nl = data:find("\n", pos, true)
      local line
      if nl then line = data:sub(pos, nl - 1) pos = nl + 1 else line = data:sub(pos) pos = #data + 1 end
      return line
    end
    function h.close() end
    return h
  elseif mode == "w" or mode == "a" or mode == "wb" then
    local acc = (mode == "a" and files[p]) or ""
    local h = {}
    function h.write(s) acc = acc .. tostring(s) end
    function h.writeLine(s) acc = acc .. tostring(s) .. "\n" end
    function h.flush() files[p] = acc end
    function h.close() files[p] = acc end
    return h
  end
  return nil, "Unsupported mode"
end
M.files = files

------------------------------------------------------------------ textutils
textutils = {}
local function ser(v, indent, seen)
  local t = type(v)
  if t == "number" or t == "boolean" or t == "nil" then return tostring(v)
  elseif t == "string" then return string.format("%q", v)
  elseif t == "table" then
    if seen[v] then error("Cannot serialize table with recursive entries", 0) end
    seen[v] = true
    local parts, n = {}, 0
    for i, e in ipairs(v) do parts[#parts + 1] = ser(e, indent .. "  ", seen) n = i end
    local ks = {}
    for k in pairs(v) do
      if not (type(k) == "number" and k >= 1 and k <= n and math.floor(k) == k) then ks[#ks + 1] = k end
    end
    table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(ks) do
      local kk
      if type(k) == "string" and k:match("^[%a_][%w_]*$") then kk = k else kk = "[" .. ser(k, "", seen) .. "]" end
      parts[#parts + 1] = kk .. " = " .. ser(v[k], indent .. "  ", seen)
    end
    seen[v] = nil
    if #parts == 0 then return "{}" end
    return "{\n" .. indent .. "  " .. table.concat(parts, ",\n" .. indent .. "  ") .. ",\n" .. indent .. "}"
  end
  error("Cannot serialize type " .. t, 0)
end
function textutils.serialize(v) return ser(v, "", {}) end
function textutils.unserialize(s)
  if type(s) ~= "string" then return nil end
  local f = load("return " .. s, "unserialize", "t", {})
  if not f then return nil end
  local ok, res = pcall(f)
  if not ok then return nil end
  return res
end
textutils.serialise, textutils.unserialise = textutils.serialize, textutils.unserialize
function textutils.formatTime(t, tf)
  local h = math.floor(t) % 24
  local m = math.floor((t % 1) * 60)
  if tf then return string.format("%02d:%02d", h, m) end
  local ampm = h < 12 and "AM" or "PM"
  local hh = h % 12
  if hh == 0 then hh = 12 end
  return string.format("%d:%02d %s", hh, m, ampm)
end

------------------------------------------------------------------ peripheral
M.notes = {}
M.speakerPresent = true
local speaker = {
  playNote = function(inst, vol, pitch)
    if type(inst) ~= "string" then error("bad instrument " .. tostring(inst), 2) end
    if vol and (vol < 0 or vol > 3) then error("Volume out of range: " .. tostring(vol), 2) end
    if pitch and (pitch < 0 or pitch > 24) then error("Pitch out of range: " .. tostring(pitch), 2) end
    if pitch and math.floor(pitch) ~= pitch then error("Pitch must be an integer: " .. tostring(pitch), 2) end
    M.notes[#M.notes + 1] = { inst = inst, vol = vol, pitch = pitch, t = vclock }
    return true
  end,
  playSound = function() return true end,
  stop = function() end,
}
----------------------------------------------------------------------- modem
-- A modem plus a virtual ether, so console-to-console play can be tested
-- without a second Lua state. Anything transmitted lands in M.ether as a
-- record, and M.deliver() turns a record into the modem_message event the
-- receiving side would actually see. A test can therefore play the part of
-- the other console: read what we sent, and answer.
M.modemPresent = true
M.ether = {}                 -- every transmit, in order
M.openChannels = {}

local modem = {
  isWireless = function() return true end,
  open = function(ch)
    if type(ch) ~= "number" or ch < 0 or ch > 65535 then
      error("Expected number in range 0-65535", 2)
    end
    M.openChannels[ch] = true
  end,
  close = function(ch) M.openChannels[ch] = nil end,
  isOpen = function(ch) return M.openChannels[ch] == true end,
  closeAll = function() M.openChannels = {} end,
  transmit = function(ch, reply, body)
    if type(ch) ~= "number" or type(reply) ~= "number" then
      error("Expected number, number, message", 2)
    end
    M.ether[#M.ether + 1] = { channel = ch, reply = reply, body = body, t = vclock }
    return true
  end,
}

--- Queue the modem_message event a transmit on `channel` would produce here.
--- Delivery is not automatic: the ether is one-way by design, so a test says
--- explicitly what the far console sent back.
function M.deliver(channel, reply, body, distance)
  M.push("modem_message", "back", channel, reply, body, distance or 12)
end

--- The most recent thing we transmitted, optionally filtered by message type.
function M.lastSent(kind)
  for i = #M.ether, 1, -1 do
    local rec = M.ether[i]
    if not kind or (type(rec.body) == "table" and rec.body.t == kind) then return rec end
  end
  return nil
end

function M.clearEther() M.ether = {} end

local function sideType(side)
  if M.speakerPresent and side == "left" then return "speaker" end
  if M.modemPresent and side == "back" then return "modem" end
  return nil
end

peripheral = {}
function peripheral.find(kind)
  if kind == "speaker" and M.speakerPresent then return speaker end
  if kind == "modem" and M.modemPresent then return modem end
  return nil
end
function peripheral.getNames()
  local out = {}
  if M.speakerPresent then out[#out + 1] = "left" end
  if M.modemPresent then out[#out + 1] = "back" end
  return out
end
function peripheral.isPresent(side) return sideType(side) ~= nil end
function peripheral.getType(side) return sideType(side) end
function peripheral.wrap(side)
  local kind = sideType(side)
  if kind == "speaker" then return speaker end
  if kind == "modem" then return modem end
  return nil
end

-------------------------------------------------------------------- parallel
parallel = {}
local function runCoroutines(waitAll, ...)
  local fns = { ... }
  local routines, filters = {}, {}
  for i, f in ipairs(fns) do routines[i] = coroutine.create(f) end
  local eventData = {}
  while true do
    for i, co in ipairs(routines) do
      if coroutine.status(co) ~= "dead" then
        if filters[i] == nil or filters[i] == eventData[1] or eventData[1] == "terminate" then
          local ok, res = coroutine.resume(co, table.unpack(eventData))
          if not ok then error(res, 0) end
          filters[i] = res
        end
      end
    end
    local finished = 0
    for _, co in ipairs(routines) do if coroutine.status(co) == "dead" then finished = finished + 1 end end
    if (waitAll and finished == #routines) or (not waitAll and finished > 0) then return finished end
    eventData = { os.pullEventRaw() }
  end
end
function parallel.waitForAll(...) return runCoroutines(true, ...) end
function parallel.waitForAny(...) return runCoroutines(false, ...) end

-------------------------------------------------------------------- snapshot
function M.snapshot()
  local b = native.__buffer
  local rows = {}
  for y = 1, b.h do
    local codes = {}
    for x = 1, b.w do codes[x] = string.byte(b.ch[y][x]) end
    rows[y] = { ch = codes, fg = table.concat(b.fg[y]), bg = table.concat(b.bg[y]) }
  end
  local pal = {}
  for i = 1, 16 do pal[i] = native.__palette[ORDER[i]] or 0 end
  return { w = b.w, h = b.h, rows = rows, palette = pal }
end

_G.MOCK = M
return M
