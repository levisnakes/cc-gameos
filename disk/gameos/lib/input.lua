--[[ input -- key and mouse state for a frame-based game loop.

  The runtime feeds raw CC events in and calls endFrame() after each update.
  Games ask three questions:
    input.down(...)     is the key held right now
    input.pressed(...)  was it pressed fresh this frame
    input.repeated(...) pressed, or auto-repeating because it is held
]]

local input = {}

input.held = {}
input.hit = {}
input.rep = {}
input.chars = {}
input.mouseEvents = {}
input.mouseX, input.mouseY = 0, 0

function input.reset()
  for k in pairs(input.held) do input.held[k] = nil end
  input.clearFrame()
end

function input.clearFrame()
  for k in pairs(input.hit) do input.hit[k] = nil end
  for k in pairs(input.rep) do input.rep[k] = nil end
  for i = #input.chars, 1, -1 do input.chars[i] = nil end
  for i = #input.mouseEvents, 1, -1 do input.mouseEvents[i] = nil end
end

input.endFrame = input.clearFrame

function input.onKey(code, held)
  if not held then input.hit[code] = true end
  input.rep[code] = true
  input.held[code] = true
end

function input.onKeyUp(code)
  input.held[code] = nil
end

function input.onChar(ch)
  input.chars[#input.chars + 1] = ch
end

function input.onMouse(kind, btn, x, y)
  input.mouseEvents[#input.mouseEvents + 1] = { kind = kind, btn = btn, x = x, y = y }
  input.mouseX, input.mouseY = x, y
end

local function anyOf(set, ...)
  for i = 1, select("#", ...) do
    if set[(select(i, ...))] then return true end
  end
  return false
end

function input.down(...) return anyOf(input.held, ...) end
function input.pressed(...) return anyOf(input.hit, ...) end
function input.repeated(...) return anyOf(input.rep, ...) end

function input.anyPressed()
  for _ in pairs(input.hit) do return true end
  return false
end

--- -1 / 0 / +1 from a pair of key groups. Each argument is a list of codes.
function input.axis(negKeys, posKeys)
  local n = anyOf(input.held, table.unpack(negKeys))
  local p = anyOf(input.held, table.unpack(posKeys))
  if n and not p then return -1 end
  if p and not n then return 1 end
  return 0
end

---------------------------------------------------------------- key groups
input.LEFT = { keys.left, keys.a }
input.RIGHT = { keys.right, keys.d }
input.UP = { keys.up, keys.w }
input.DOWN = { keys.down, keys.s }
input.CONFIRM = { keys.enter, keys.space, keys.numPadEnter }
input.BACK = { keys.backspace, keys.q }
input.PAUSE = { keys.p }

--- Convenience wrappers over the standard groups.
function input.leftDown() return input.down(table.unpack(input.LEFT)) end
function input.rightDown() return input.down(table.unpack(input.RIGHT)) end
function input.upDown() return input.down(table.unpack(input.UP)) end
function input.downDown() return input.down(table.unpack(input.DOWN)) end
function input.leftHit() return input.pressed(table.unpack(input.LEFT)) end
function input.rightHit() return input.pressed(table.unpack(input.RIGHT)) end
function input.upHit() return input.pressed(table.unpack(input.UP)) end
function input.downHit() return input.pressed(table.unpack(input.DOWN)) end
function input.confirmHit() return input.pressed(table.unpack(input.CONFIRM)) end
function input.backHit() return input.pressed(table.unpack(input.BACK)) end

--- Horizontal / vertical axis using the standard groups.
function input.dx() return input.axis(input.LEFT, input.RIGHT) end
function input.dy() return input.axis(input.UP, input.DOWN) end

--[[ A key that auto-repeats on a timer of our own, so games get arcade-style
     "delayed auto shift" instead of the terminal's typing repeat. ]]
local Repeater = {}
Repeater.__index = Repeater

function input.repeater(delay, rate)
  return setmetatable({ delay = delay or 0.17, rate = rate or 0.045, t = 0, armed = false }, Repeater)
end

--- Call once per frame with whether the key is held; returns how many
--- discrete steps to apply this frame.
function Repeater:update(isDown, dt)
  if not isDown then
    self.armed = false
    self.t = 0
    return 0
  end
  if not self.armed then
    self.armed = true
    self.t = self.delay
    return 1
  end
  self.t = self.t - dt
  local steps = 0
  while self.t <= 0 do
    steps = steps + 1
    self.t = self.t + self.rate
    if steps > 12 then break end
  end
  return steps
end

return input
