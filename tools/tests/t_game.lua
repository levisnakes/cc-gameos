-- Drives one game module directly: random input fuzz plus screenshots.
-- usage: node run.mjs tests/t_game.lua <id> [mode] [frames] [shot,frames]

local req = require_gameos
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local font = req("lib.font")
local input = req("lib.input")
local audio = req("lib.audio")
local data = req("lib.data")

local id = ARGS[1] or "snake"
local modeIdx = tonumber(ARGS[2] or "1")
local frames = tonumber(ARGS[3] or "400")
local shotAt = {}
for s in tostring(ARGS[4] or "1,60,200,400"):gmatch("[^,]+") do
  shotAt[tonumber(s)] = true
end

check(gfx.init(), "gfx.init")
data.load()
audio.init()

local api = {
  version = "test", gfx = gfx, canvas = Canvas, font = font,
  input = input, audio = audio, data = data, ui = req("lib.ui"),
  require = req,
}

local def = req("games." .. id)
check(type(def) == "table", "module returns a table")
check(type(def.new) == "function", "module exposes new()")
check(type(def.name) == "string", "module has a name")
check(def.accent ~= nil, "module has an accent colour")

local mode = def.modes and def.modes[modeIdx] or nil

-- new() must not block on events. Starving the event budget around the
-- constructor turns "opened a dialog in new()" into a fast, clear failure
-- instead of a hang.
local savedBudget = MOCK.eventBudget
MOCK.eventBudget = 40
local built, inst = pcall(def.new, api, mode)
MOCK.eventBudget = savedBudget
check(built, "new() returns without waiting for input: " .. tostring(inst))
if not built then error("construction failed", 0) end
check(type(inst) == "table", "new() returns an instance")
check(type(inst.update) == "function", "instance has update")
check(type(inst.draw) == "function", "instance has draw")

local FUZZ = {
  keys.left, keys.right, keys.up, keys.down, keys.space, keys.z, keys.x,
  keys.c, keys.f, keys.enter, keys.r, keys.u, keys.m, keys.one, keys.two,
  keys.leftShift, keys.tab,
}

local function sendKey(code)
  input.onKey(code, false)
  if inst.onKey then inst:onKey(code, false) end
end

local function sendMouse(btn, x, y)
  input.onMouse("mouse_click", btn, x, y)
  if inst.onMouse then inst:onMouse("mouse_click", btn, x, y) end
end

local ended = nil
for f = 1, frames do
  if f % 7 == 0 then sendKey(FUZZ[math.random(1, #FUZZ)]) end
  if f % 23 == 0 then sendMouse(math.random(1, 2), math.random(1, 51), math.random(1, 19)) end
  if f % 11 == 0 then input.onKeyUp(FUZZ[math.random(1, #FUZZ)]) end

  inst:update(0.05)
  audio.update(f * 0.05)
  gfx.beginFrame()
  inst:draw()
  gfx.endFrame()
  input.endFrame()

  if shotAt[f] then SHOT(id .. "-f" .. f) end

  if inst.finished then ended = "finished@" .. f break end
  if inst.quit then ended = "quit@" .. f break end
end

LOG("  " .. id .. ": " .. (ended or ("ran " .. frames .. " frames")) ..
    ", score " .. tostring(inst.score))

-- score must be a number the score table can store
check(inst.score == nil or type(inst.score) == "number", "score is numeric")
if inst.summary then
  local rows = inst:summary()
  check(type(rows) == "table", "summary returns a table")
end

-- the shell cover must render without touching game state
if def.cover then
  local cov = Canvas.new(23, 3, 28, 7, colors.black)
  gfx.beginFrame()
  gfx.clear(colors.black)
  for i = 0, 4 do
    cov:clear(colors.black)
    def.cover(cov, i * 0.37)
  end
  cov:render()
  gfx.endFrame()
  SHOT(id .. "-cover")
end

gfx.shutdown()
finish("game:" .. id)
