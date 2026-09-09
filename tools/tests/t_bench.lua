-- Counts the real per-frame cost of every game: pixel writes, cell
-- resolutions and characters pushed to the terminal. This is the number that
-- decides whether the console holds 20 FPS on an actual ComputerCraft
-- computer, so it is measured rather than guessed at.
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
  version = "bench", gfx = gfx, canvas = Canvas, font = font,
  input = input, audio = audio, data = data, ui = req("lib.ui"), require = req,
}

------------------------------------------------------------------ counters
local count = { px = 0, cells = 0, blitChars = 0, blitCalls = 0, termWrite = 0 }

local realSet = Canvas.set
Canvas.set = function(self, x, y, col)
  count.px = count.px + 1
  return realSet(self, x, y, col)
end

local realFill = Canvas.fill
Canvas.fill = function(self, x, y, w, h, col)
  if w > 0 and h > 0 then count.px = count.px + w * h end
  return realFill(self, x, y, w, h, col)
end

local realClear = Canvas.clear
Canvas.clear = function(self, col)
  count.px = count.px + self.w * self.h
  return realClear(self, col)
end

local realRender = Canvas.render
Canvas.render = function(self)
  count.cells = count.cells + self.cw * self.ch
  return realRender(self)
end

local realBlit = term.blit
term.blit = function(text, f, b)
  count.blitCalls = count.blitCalls + 1
  count.blitChars = count.blitChars + #text
  return realBlit(text, f, b)
end
local realWrite = term.write
term.write = function(s)
  count.termWrite = count.termWrite + #tostring(s)
  return realWrite(s)
end

local function reset()
  count.px, count.cells, count.blitChars, count.blitCalls, count.termWrite = 0, 0, 0, 0, 0
end

------------------------------------------------------------------ measure
local SPECS = {
  { "snake", 1 }, { "tetris", 1 }, { "breakout", 1 }, { "bombard", 2 },
  { "minesweeper", 3 }, { "g2048", 1 }, { "sokoban", 1 }, { "flappy", 1 },
  { "pong", 2 }, { "meteors", 1 }, { "lightsout", 1 }, { "simon", 1 },
  { "connect4", 4 },
}

local FRAMES = 120
local worst = { name = "", total = 0 }

LOG(string.format("%-13s %9s %8s %9s %8s   %s", "game", "px/frame",
  "cells", "blit ch", "text ch", "est. ops/frame"))

for _, spec in ipairs(SPECS) do
  local def = req("games." .. spec[1])
  local inst = def.new(api, def.modes and def.modes[spec[2]])
  -- warm up so the first-frame allocations do not skew the average
  for _ = 1, 5 do
    inst:update(0.05)
    gfx.beginFrame() inst:draw() gfx.endFrame()
    input.endFrame()
  end
  reset()
  local frames = 0
  for _ = 1, FRAMES do
    if inst.finished then break end
    frames = frames + 1
    inst:update(0.05)
    gfx.beginFrame()
    inst:draw()
    gfx.endFrame()
    input.endFrame()
  end
  frames = math.max(1, frames)

  local px = count.px / frames
  local cells = count.cells / frames
  local blitCh = count.blitChars / frames
  local textCh = count.termWrite / frames
  -- a pixel write is ~1 table store; resolving a cell is ~10 ops in the
  -- two-colour fast path; a blit character is ~2 ops of string building
  local ops = px + cells * 10 + blitCh * 2
  if ops > worst.total then worst = { name = def.name, total = ops } end
  LOG(string.format("%-13s %9d %8d %9d %8d   %d", def.name,
    math.floor(px), math.floor(cells), math.floor(blitCh), math.floor(textCh),
    math.floor(ops)))
end

LOG("")
LOG(string.format("worst case: %s at about %d ops per frame, %d per second at 20 FPS",
  worst.name, worst.total, worst.total * 20))

check(worst.total < 120000, "worst-case frame stays under the budget")

gfx.shutdown()
finish("bench")
