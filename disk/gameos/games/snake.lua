--[[ Snake -- 32x16 board of 3px cells on the pixel canvas.

  Turns are buffered two deep so a quick left-then-up around a corner never
  gets eaten by the movement tick.
]]

local req = ...
local gfx = req("lib.gfx")
local font = req("lib.font")
local audio = req("lib.audio")

local COLS, ROWS = 32, 16
local CELL = 3
local OX, OY = 4, 4

local Game = {}
Game.__index = Game

local floor = math.floor

------------------------------------------------------------------ helpers
local function key(x, y) return (y - 1) * COLS + x end

local DIRS = {
  up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 },
}

local MAZES = {
  -- {x, y, w, h} blocks in cell coordinates
  { { 8, 4, 2, 9 }, { 24, 4, 2, 9 }, { 13, 7, 7, 2 } },
}

------------------------------------------------------------------ instance
local function new(api, mode)
  local self = setmetatable({}, Game)
  self.api = api
  self.mode = (mode and mode.id) or "classic"
  self.c = api.canvas.new(1, 2, gfx.W, 18, colors.black)

  self.walls = {}
  if self.mode == "maze" then
    for _, block in ipairs(MAZES[1]) do
      for y = block[2], block[2] + block[4] - 1 do
        for x = block[1], block[1] + block[3] - 1 do
          self.walls[key(x, y)] = true
        end
      end
    end
  end

  self.occ = {}
  self.body = {}
  self.head = 0
  self.tail = 1
  local sy = floor(ROWS / 2)
  for i = 1, 4 do
    self.head = self.head + 1
    self.body[self.head] = { x = 6 + i, y = sy }
    self.occ[key(6 + i, sy)] = true
  end

  self.dir = DIRS.right
  self.queue = {}
  self.grow = 0
  self.score = 0
  self.apples = 0
  self.level = 1
  self.tick = 0
  self.interval = 0.135
  self.finished = false
  self.dying = 0
  self.flash = 0
  self.bonus = nil
  self.bonusIn = 5
  self.food = nil
  self:spawnFood()
  return self
end

function Game:length() return self.head - self.tail + 1 end

function Game:freeCell()
  for _ = 1, 400 do
    local x = math.random(1, COLS)
    local y = math.random(1, ROWS)
    local k = key(x, y)
    if not self.occ[k] and not self.walls[k] and
       not (self.food and self.food.x == x and self.food.y == y) and
       not (self.bonus and self.bonus.x == x and self.bonus.y == y) then
      return x, y
    end
  end
  -- board is nearly full: fall back to a linear scan
  for y = 1, ROWS do
    for x = 1, COLS do
      local k = key(x, y)
      if not self.occ[k] and not self.walls[k] then return x, y end
    end
  end
  return nil
end

function Game:spawnFood()
  local x, y = self:freeCell()
  if x then self.food = { x = x, y = y } else self.food = nil end
end

function Game:spawnBonus()
  local x, y = self:freeCell()
  if x then self.bonus = { x = x, y = y, life = 7, max = 7 } end
end

------------------------------------------------------------------- control
local OPPOSITE = { up = "down", down = "up", left = "right", right = "left" }

function Game:turn(name)
  if self.dying > 0 then return end
  -- compare against the last queued turn, not the current heading, so a
  -- two-key corner registers correctly
  local last = self.lastQueued
  if not last then
    for n, d in pairs(DIRS) do
      if d == self.dir then last = n break end
    end
  end
  if name == last or OPPOSITE[name] == last then return end
  if #self.queue >= 2 then return end
  self.queue[#self.queue + 1] = name
  self.lastQueued = name
end

function Game:onKey(code, held)
  if held then return end
  if code == keys.up or code == keys.w then self:turn("up")
  elseif code == keys.down or code == keys.s then self:turn("down")
  elseif code == keys.left or code == keys.a then self:turn("left")
  elseif code == keys.right or code == keys.d then self:turn("right")
  end
end

-------------------------------------------------------------------- update
function Game:die()
  if self.dying > 0 then return end
  self.dying = 0.9
  audio.play("explode")
end

function Game:step()
  local name = table.remove(self.queue, 1)
  if name then
    self.dir = DIRS[name]
    if #self.queue == 0 then self.lastQueued = name end
  end

  local h = self.body[self.head]
  local nx = h.x + self.dir[1]
  local ny = h.y + self.dir[2]

  if self.mode == "wrap" then
    if nx < 1 then nx = COLS elseif nx > COLS then nx = 1 end
    if ny < 1 then ny = ROWS elseif ny > ROWS then ny = 1 end
  elseif nx < 1 or nx > COLS or ny < 1 or ny > ROWS then
    return self:die()
  end

  local k = key(nx, ny)
  if self.walls[k] then return self:die() end

  -- the tail cell is about to move away, so running into it is legal
  local tailCell = self.body[self.tail]
  local movingTail = (self.grow == 0 and tailCell.x == nx and tailCell.y == ny)
  if self.occ[k] and not movingTail then return self:die() end

  if self.grow > 0 then
    self.grow = self.grow - 1
  else
    self.occ[key(tailCell.x, tailCell.y)] = nil
    self.body[self.tail] = nil
    self.tail = self.tail + 1
  end

  self.head = self.head + 1
  self.body[self.head] = { x = nx, y = ny }
  self.occ[k] = true

  if self.food and self.food.x == nx and self.food.y == ny then
    self.apples = self.apples + 1
    self.grow = self.grow + 2
    self.level = floor(self.apples / 5) + 1
    self.score = self.score + 10 * self.level
    self.interval = math.max(0.055, 0.135 - self.apples * 0.0022)
    self.flash = 0.12
    audio.play("eat", math.min(8, floor(self.apples / 2)))
    self:spawnFood()
    self.bonusIn = self.bonusIn - 1
    if self.bonusIn <= 0 and not self.bonus then
      self.bonusIn = 6
      self:spawnBonus()
    end
  elseif self.bonus and self.bonus.x == nx and self.bonus.y == ny then
    local worth = 50 + floor(self.bonus.life * 12)
    self.score = self.score + worth
    self.grow = self.grow + 3
    self.bonus = nil
    self.flash = 0.2
    audio.play("coin")
  end
end

function Game:update(dt)
  if self.flash > 0 then self.flash = self.flash - dt end

  if self.dying > 0 then
    self.dying = self.dying - dt
    if self.dying <= 0 then self.finished = true end
    return
  end

  if self.bonus then
    self.bonus.life = self.bonus.life - dt
    if self.bonus.life <= 0 then self.bonus = nil end
  end

  self.tick = self.tick + dt
  local guard = 0
  while self.tick >= self.interval and self.dying <= 0 and guard < 4 do
    self.tick = self.tick - self.interval
    guard = guard + 1
    self:step()
  end
end

---------------------------------------------------------------------- draw
local function cellRect(x, y)
  return OX + (x - 1) * CELL, OY + (y - 1) * CELL
end

function Game:draw()
  local c = self.c
  c:clear(colors.black)

  local border = self.dying > 0 and colors.red or colors.gray
  c:box(3, 3, 98, 50, border)
  if self.mode == "wrap" then
    -- dashed border reads as "open"
    for x = 3, 100, 6 do
      c:fill(x, 3, 3, 1, colors.black)
      c:fill(x, 52, 3, 1, colors.black)
    end
  end

  for k in pairs(self.walls) do
    local x = (k - 1) % COLS + 1
    local y = floor((k - 1) / COLS) + 1
    local px, py = cellRect(x, y)
    c:fill(px, py, CELL, CELL, colors.gray)
    c:fill(px, py, CELL, 1, colors.lightGray)
  end

  if self.food then
    local px, py = cellRect(self.food.x, self.food.y)
    c:fill(px, py, 3, 3, colors.red)
    c:set(px, py, colors.black)
    c:set(px + 2, py, colors.lime)
    c:set(px + 1, py + 1, colors.orange)
  end

  if self.bonus then
    local px, py = cellRect(self.bonus.x, self.bonus.y)
    local on = (self.bonus.life > 2) or (floor(self.bonus.life * 8) % 2 == 0)
    if on then
      c:fill(px, py, 3, 3, colors.yellow)
      c:set(px + 1, py + 1, colors.orange)
    end
  end

  local dyingBlink = self.dying > 0 and floor(self.dying * 12) % 2 == 0
  local i = self.tail
  while i <= self.head do
    local seg = self.body[i]
    local px, py = cellRect(seg.x, seg.y)
    local isHead = (i == self.head)
    local col
    if dyingBlink then
      col = colors.red
    elseif isHead then
      col = colors.white
    else
      col = ((self.head - i) % 6 < 3) and colors.lime or colors.green
    end
    c:fill(px, py, CELL, CELL, col)
    if isHead and not dyingBlink then
      local dx = self.dir[1]
      if dx ~= 0 then
        c:set(px + 1, py, colors.black)
        c:set(px + 1, py + 2, colors.black)
      else
        c:set(px, py + 1, colors.black)
        c:set(px + 2, py + 1, colors.black)
      end
    end
    i = i + 1
  end

  c:render()

  local hudBg = self.flash > 0 and colors.green or colors.gray
  gfx.fill(1, 1, gfx.W, 1, hudBg)
  gfx.text(2, 1, "SCORE", colors.lightGray, hudBg)
  gfx.text(8, 1, gfx.commas(self.score), colors.white, hudBg)
  gfx.center(1, "LEN " .. self:length(), colors.lime, hudBg)
  gfx.right(gfx.W - 1, 1, "LV " .. self.level, colors.yellow, hudBg)
end

function Game:summary()
  return {
    { "Length", self:length() },
    { "Apples", self.apples },
    { "Level", self.level },
  }
end

---------------------------------------------------------------------- cover
local function cover(c, t)
  c:clear(colors.black)
  for y = 3, c.h - 2, 5 do
    for x = 3, c.w - 2, 5 do c:set(x, y, colors.gray) end
  end

  -- an apple the head is always just about to reach
  local hp = t * 20
  local hx = 4 + (hp % (c.w + 30))
  local ax = hx + 14
  if ax <= c.w - 3 then
    c:fill(ax, 9, 3, 3, colors.red)
    c:set(ax + 2, 9, colors.lime)
  end

  for i = 20, 1, -1 do
    local p = hp - i * 3
    local x = 4 + (p % (c.w + 30))
    local y = 11 + math.sin(p * 0.10) * 6
    if x <= c.w - 2 then
      local col = (i % 6 < 3) and colors.lime or colors.green
      if i == 1 then col = colors.white end
      c:fill(x, floor(y), 3, 3, col)
      if i == 1 then
        c:set(x + 1, floor(y), colors.black)
        c:set(x + 1, floor(y) + 2, colors.black)
      end
    end
  end
end

----------------------------------------------------------------- definition
return {
  id = "snake",
  name = "Snake",
  tagline = "Eat. Grow. Mind the tail.",
  accent = colors.lime,
  order = 10,
  cover = cover,
  controls = {
    { "Arrows/WASD", "Turn" },
    { "P", "Pause menu" },
  },
  modes = {
    { id = "classic", name = "Classic", hint = "walls kill" },
    { id = "wrap", name = "Wrap-around", hint = "no walls" },
    { id = "maze", name = "Maze", hint = "obstacles" },
  },
  trophies = {
    { id = "snake_25", name = "Snack Time", desc = "Eat 25 apples in one run",
      test = function(g) return g.apples >= 25 end },
    { id = "snake_50", name = "Orchard Raid", desc = "Eat 50 apples in one run",
      test = function(g) return g.apples >= 50 end },
    { id = "snake_long", name = "Long Boy", desc = "Grow to 40 segments",
      test = function(g) return g:length() >= 40 end },
  },
  new = new,
}
