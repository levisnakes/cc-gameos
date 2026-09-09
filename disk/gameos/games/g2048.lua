--[[ 2048 -- slide, merge, repeat.

  Big character-cell tiles with a one-step undo. Tile text colour comes from
  gfx.contrast so every palette theme stays readable.
]]

local req = ...
local gfx = req("lib.gfx")
local audio = req("lib.audio")

local floor = math.floor
local min, max = math.min, math.max

local Game = {}
Game.__index = Game

local N = 4
local TILE_W, TILE_H = 10, 3
-- three frames at 20 FPS: enough to read as a slide, short enough to stay snappy
local SLIDE_TIME = 0.15
local BOARD_X, BOARD_Y = 4, 2

local TILE_BG = {
  [2] = colors.lightGray, [4] = colors.white, [8] = colors.orange,
  [16] = colors.red, [32] = colors.magenta, [64] = colors.purple,
  [128] = colors.yellow, [256] = colors.lime, [512] = colors.cyan,
  [1024] = colors.lightBlue, [2048] = colors.pink, [4096] = colors.green,
  [8192] = colors.blue,
}

local function tileColour(v)
  return TILE_BG[v] or colors.white
end

local function tilePos(col, row)
  return BOARD_X + 1 + (col - 1) * (TILE_W + 1), BOARD_Y + 1 + (row - 1) * (TILE_H + 1)
end

------------------------------------------------------------------ instance
local function new(api, mode)
  local self = setmetatable({}, Game)
  self.api = api
  self.grid = {}
  for i = 1, N * N do self.grid[i] = 0 end
  self.score = 0
  self.moves = 0
  self.biggest = 0
  self.finished = false
  self.won = false
  self.reached2048 = false
  self.undoGrid = nil
  self.pop = {}
  self.slides = nil
  self.slideTime = 0
  self.message = nil
  self.messageTime = 0
  self:spawn()
  self:spawn()
  return self
end

function Game:get(col, row) return self.grid[(row - 1) * N + col] end
function Game:set(col, row, v) self.grid[(row - 1) * N + col] = v end

function Game:spawn()
  local free = {}
  for i = 1, N * N do
    if self.grid[i] == 0 then free[#free + 1] = i end
  end
  if #free == 0 then return false end
  local idx = free[math.random(1, #free)]
  self.grid[idx] = (math.random(1, 10) == 1) and 4 or 2
  self.pop[idx] = 0.18
  return true
end

function Game:say(text)
  self.message = text
  self.messageTime = 1.8
end

------------------------------------------------------------------ movement
--- Collapse one line towards index 1. Returns the new line, points scored,
--- which output slots ended up merged, and where every tile travelled so the
--- move can be animated.
local function slideLine(line)
  local out, merged, moves = {}, {}, {}
  local gained = 0
  local pending = nil
  for i = 1, N do
    local v = line[i]
    if v ~= 0 then
      if pending == v then
        out[#out] = v * 2
        merged[#out] = true
        gained = gained + v * 2
        moves[#moves + 1] = { from = i, to = #out, value = v }
        pending = nil
      else
        out[#out + 1] = v
        moves[#moves + 1] = { from = i, to = #out, value = v }
        pending = v
      end
    end
  end
  for i = #out + 1, N do out[i] = 0 end
  return out, gained, merged, moves
end

local READ = {
  left = function(i, j) return j, i end,
  right = function(i, j) return N + 1 - j, i end,
  up = function(i, j) return i, j end,
  down = function(i, j) return i, N + 1 - j end,
}

function Game:move(dir)
  if self.finished then return false end
  -- a press during the slide is remembered rather than dropped, so quick
  -- play never feels like it is eating inputs
  if self.slideTime > 0 then
    if READ[dir] then self.queued = dir end
    return false
  end
  local map = READ[dir]
  if not map then return false end

  local snapshot = {}
  for i = 1, N * N do snapshot[i] = self.grid[i] end

  local line = {}
  local changed = false
  local gained = 0
  local popped = {}
  local slides = {}

  for i = 1, N do
    for j = 1, N do
      local col, row = map(i, j)
      line[j] = self:get(col, row)
    end
    local out, points, merged, moves = slideLine(line)
    gained = gained + points
    for _, mv in ipairs(moves) do
      local fx, fy = map(i, mv.from)
      local tx, ty = map(i, mv.to)
      if fx ~= tx or fy ~= ty then changed = true end
      slides[#slides + 1] = { value = mv.value, fx = fx, fy = fy, tx = tx, ty = ty }
    end
    for j = 1, N do
      local col, row = map(i, j)
      if self:get(col, row) ~= out[j] then changed = true end
      self:set(col, row, out[j])
      if merged[j] then popped[(row - 1) * N + col] = true end
    end
  end

  if not changed then
    audio.play("g2048.deny")
    return false
  end

  self.undoGrid = snapshot
  self.undoScore = self.score
  self.score = self.score + gained
  self.moves = self.moves + 1
  self.pendingPop = popped
  self.slides = slides
  self.slideTime = SLIDE_TIME
  if gained > 0 then
    -- bigger merges ring higher
    audio.play("g2048.merge", min(10, floor(gained / 32)))
  else
    audio.play("g2048.slide")
  end
  return true
end

--- Called once the slide animation has played out.
function Game:settle()
  self.slides = nil
  for idx in pairs(self.pendingPop or {}) do self.pop[idx] = 0.2 end
  self.pendingPop = nil
  self:spawn()
  self:afterMove()
  local queued = self.queued
  self.queued = nil
  if queued and not self.finished then self:move(queued) end
end

function Game:afterMove()
  self.biggest = 0
  for i = 1, N * N do
    if self.grid[i] > self.biggest then self.biggest = self.grid[i] end
  end
  if self.biggest >= 2048 and not self.reached2048 then
    self.reached2048 = true
    self.won = true
    self:say("2048! KEEP GOING")
    audio.play("result.win")
  end
  if not self:hasMove() then
    self.finished = true
    audio.play("result.lose")
  end
end

function Game:hasMove()
  for i = 1, N * N do
    if self.grid[i] == 0 then return true end
  end
  for row = 1, N do
    for col = 1, N do
      local v = self:get(col, row)
      if col < N and self:get(col + 1, row) == v then return true end
      if row < N and self:get(col, row + 1) == v then return true end
    end
  end
  return false
end

function Game:undo()
  if self.slideTime > 0 then return end
  if not self.undoGrid then
    audio.play("g2048.deny")
    return
  end
  for i = 1, N * N do self.grid[i] = self.undoGrid[i] end
  self.score = self.undoScore or self.score
  self.undoGrid = nil
  self.finished = false
  self.moves = math.max(0, self.moves - 1)
  audio.play("g2048.undo")
  self:say("UNDO")
end

--------------------------------------------------------------------- input
function Game:onKey(code, held)
  if code == keys.left or code == keys.a then
    self:move("left")
  elseif code == keys.right or code == keys.d then
    self:move("right")
  elseif code == keys.up or code == keys.w then
    self:move("up")
  elseif code == keys.down or code == keys.s then
    self:move("down")
  elseif code == keys.u and not held then
    self:undo()
  end
end

--- Two ways to play with a pointer: swipe across the board, or click toward
--- an edge. The swipe is the natural gesture and takes priority; a click that
--- goes nowhere falls back to the edge rule so a single tap still moves.
function Game:onMouse(kind, btn, x, y)
  if kind == "mouse_click" then
    self.dragFrom = { x, y }
    self.dragged = false
    return
  end

  if kind == "mouse_drag" and self.dragFrom then
    local dx = x - self.dragFrom[1]
    local dy = y - self.dragFrom[2]
    -- characters are about twice as wide as they are tall, so horizontal
    -- distance has to be scaled up before the two axes can be compared
    local hx, hy = dx * 2, dy * 3
    if not self.dragged and (hx * hx + hy * hy) >= 36 then
      self.dragged = true
      if math.abs(hx) > math.abs(hy) then
        self:move(dx > 0 and "right" or "left")
      else
        self:move(dy > 0 and "down" or "up")
      end
    end
    return
  end

  if kind == "mouse_up" then
    local from = self.dragFrom
    self.dragFrom = nil
    if self.dragged or not from then return end
    -- no swipe happened, so treat it as a click toward a screen edge
    local dx, dy = from[1] - gfx.W / 2, from[2] - gfx.H / 2
    if math.abs(dx) * 0.4 > math.abs(dy) then
      self:move(dx > 0 and "right" or "left")
    else
      self:move(dy > 0 and "down" or "up")
    end
  end
end

-------------------------------------------------------------------- update
function Game:update(dt)
  if self.slideTime > 0 then
    self.slideTime = self.slideTime - dt
    if self.slideTime <= 0 then
      self.slideTime = 0
      self:settle()
    end
  end
  for idx, t in pairs(self.pop) do
    local left = t - dt
    if left <= 0 then self.pop[idx] = nil else self.pop[idx] = left end
  end
  if self.messageTime > 0 then
    self.messageTime = self.messageTime - dt
    if self.messageTime <= 0 then self.message = nil end
  end
end

---------------------------------------------------------------------- draw
function Game:draw()
  gfx.clear(colors.black)

  gfx.fill(1, 1, gfx.W, 1, colors.gray)
  gfx.text(2, 1, "SCORE", colors.lightGray, colors.gray)
  gfx.text(8, 1, gfx.commas(self.score), colors.white, colors.gray)
  gfx.center(1, "MOVES " .. self.moves, colors.lightGray, colors.gray)
  gfx.right(gfx.W - 1, 1, "MAX " .. gfx.commas(self.biggest), colors.yellow, colors.gray)

  gfx.fill(BOARD_X, BOARD_Y, N * (TILE_W + 1) + 1, N * (TILE_H + 1) + 1, colors.gray)

  -- empty slots first, then either the sliding tiles or the settled board
  for row = 1, N do
    for col = 1, N do
      local x, y = tilePos(col, row)
      gfx.fill(x, y, TILE_W, TILE_H, colors.black)
    end
  end

  local function drawTile(x, y, v, lit)
    local bg = tileColour(v)
    gfx.fill(x, y, TILE_W, TILE_H, bg)
    if lit then
      gfx.fill(x, y, TILE_W, 1, colors.white)
      gfx.fill(x, y + TILE_H - 1, TILE_W, 1, colors.white)
    end
    gfx.center(y + 1, tostring(v), gfx.contrast(bg), bg, x, TILE_W)
  end

  if self.slides then
    local k = 1 - (self.slideTime / SLIDE_TIME)
    if k < 0 then k = 0 elseif k > 1 then k = 1 end
    for _, s in ipairs(self.slides) do
      local fx, fy = tilePos(s.fx, s.fy)
      local tx, ty = tilePos(s.tx, s.ty)
      drawTile(floor(fx + (tx - fx) * k + 0.5), floor(fy + (ty - fy) * k + 0.5), s.value)
    end
  else
    for row = 1, N do
      for col = 1, N do
        local v = self:get(col, row)
        if v ~= 0 then
          local x, y = tilePos(col, row)
          drawTile(x, y, v, self.pop[(row - 1) * N + col])
        end
      end
    end
  end

  if self.message then
    local text = self.message
    local w = #text + 4
    local x = floor((gfx.W - w) / 2) + 1
    gfx.fill(x, 10, w, 1, colors.yellow)
    gfx.center(10, text, gfx.contrast(colors.yellow), colors.yellow, x, w)
  end

  gfx.rule(1, 18, gfx.W, colors.gray, colors.black)
  gfx.center(19, "Arrows slide   U undo   P pause", colors.lightGray, colors.black)
end

function Game:summary()
  return {
    { "Biggest tile", self.biggest },
    { "Moves", self.moves },
  }
end

---------------------------------------------------------------------- cover
local COVER_VALUES = { 2, 4, 8, 16, 32, 64, 128, 256, 512 }

local function cover(c, t)
  c:clear(colors.gray)
  local cell = 6
  local ox = floor((c.w - 3 * cell - 2) / 2)
  local oy = floor((c.h - 3 * cell - 2) / 2)
  for row = 1, 3 do
    for col = 1, 3 do
      local i = (row - 1) * 3 + col
      local shift = floor(t * 1.4) % #COVER_VALUES
      local v = COVER_VALUES[((i + shift - 1) % #COVER_VALUES) + 1]
      local x = ox + (col - 1) * (cell + 1)
      local y = oy + (row - 1) * (cell + 1)
      c:fill(x, y, cell, cell, tileColour(v))
    end
  end
end

----------------------------------------------------------------- definition
return {
  id = "2048",
  name = "2048",
  tagline = "Powers of two, one grid",
  accent = colors.yellow,
  order = 60,
  cover = cover,
  music = "quiet",
  controls = {
    { "Arrows / WASD", "Slide tiles" },
    { "U", "Undo one move" },
    { "Click", "Slide that way" },
    { "Mouse", "Swipe or click an edge" },
    { "P", "Pause menu" },
  },
  trophies = {
    { id = "g2048_512", name = "Halfway", desc = "Build a 512 tile",
      test = function(g) return g.biggest >= 512 end },
    { id = "g2048_win", name = "2048!", desc = "Build the 2048 tile",
      test = function(g) return g.biggest >= 2048 end },
    { id = "g2048_10k", name = "Five Figures", desc = "Score ten thousand",
      test = function(g) return g.score >= 10000 end },
  },
  new = new,
}
