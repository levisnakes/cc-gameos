-- Dump a rectangle of a game's canvas as colour letters, for eyeballing art.
-- usage: node run.mjs tests/t_probe.lua <id> <frames> <x> <y> <w> <h>
local req = require_gameos
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local font = req("lib.font")
local input = req("lib.input")
local audio = req("lib.audio")
local data = req("lib.data")

gfx.init()
data.load()
audio.init()

local api = {
  version = "test", gfx = gfx, canvas = Canvas, font = font,
  input = input, audio = audio, data = data, ui = req("lib.ui"), require = req,
}

local id = ARGS[1]
local frames = tonumber(ARGS[2] or "30")
local x0 = tonumber(ARGS[3] or "1")
local y0 = tonumber(ARGS[4] or "1")
local w = tonumber(ARGS[5] or "16")
local h = tonumber(ARGS[6] or "40")

local def = req("games." .. id)
local inst = def.new(api, def.modes and def.modes[1])
for _ = 1, frames do
  inst:update(0.05)
  gfx.beginFrame()
  inst:draw()
  gfx.endFrame()
  input.endFrame()
end

local LETTER = {}
local names = { "white", "orange", "magenta", "lightBlue", "yellow", "lime",
  "pink", "gray", "lightGray", "cyan", "purple", "blue", "brown", "green",
  "red", "black" }
local marks = "WOMLYIPGACUBRNE."
for i = 1, 16 do LETTER[colors[names[i]]] = marks:sub(i, i) end

local c = inst.c
LOG("canvas " .. c.w .. "x" .. c.h .. "  window at (" .. c.cx .. "," .. c.cy .. ")")
LOG("     " .. string.rep("-", w))
for y = y0, math.min(c.h, y0 + h - 1) do
  local row = {}
  for x = x0, math.min(c.w, x0 + w - 1) do
    row[#row + 1] = LETTER[c:get(x, y)] or "?"
  end
  LOG(string.format("%3d |%s|", y, table.concat(row)))
end
finish("probe")
