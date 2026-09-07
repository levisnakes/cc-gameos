--[[ Tetris -- 10 wide, 18 visible rows plus 2 hidden spawn rows.

  Blocks are 4x3 canvas pixels, which is exactly two character cells wide and
  one tall, so the well renders pixel-perfect with no colour bleeding.

  Implements the modern ruleset: 7-bag randomiser, SRS rotation with the full
  wall-kick tables, hold, ghost piece, lock delay with move resets, soft/hard
  drop scoring, T-spins, back-to-back and combos.
]]

local req = ...
local gfx = req("lib.gfx")
local font = req("lib.font")
local audio = req("lib.audio")
local input = req("lib.input")

local floor = math.floor

local COLS = 10
local HIDDEN = 2
local VISIBLE = 18
local ROWS = HIDDEN + VISIBLE

local BW, BH = 4, 3
local WELL_X, WELL_Y = 33, 1

local Game = {}
Game.__index = Game

----------------------------------------------------------------- tetrominoes
-- Cells are {x, y} offsets inside the piece box, 0-based, for rotations
-- 0 (spawn), 1 (clockwise), 2 (180), 3 (counter-clockwise).
local SHAPES = {
  I = {
    { { 0, 1 }, { 1, 1 }, { 2, 1 }, { 3, 1 } },
    { { 2, 0 }, { 2, 1 }, { 2, 2 }, { 2, 3 } },
    { { 0, 2 }, { 1, 2 }, { 2, 2 }, { 3, 2 } },
    { { 1, 0 }, { 1, 1 }, { 1, 2 }, { 1, 3 } },
  },
  O = {
    { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } },
    { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } },
    { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } },
    { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } },
  },
  T = {
    { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } },
    { { 1, 0 }, { 1, 1 }, { 2, 1 }, { 1, 2 } },
    { { 0, 1 }, { 1, 1 }, { 2, 1 }, { 1, 2 } },
    { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 1, 2 } },
  },
  S = {
    { { 1, 0 }, { 2, 0 }, { 0, 1 }, { 1, 1 } },
    { { 1, 0 }, { 1, 1 }, { 2, 1 }, { 2, 2 } },
    { { 1, 1 }, { 2, 1 }, { 0, 2 }, { 1, 2 } },
    { { 0, 0 }, { 0, 1 }, { 1, 1 }, { 1, 2 } },
  },
  Z = {
    { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 2, 1 } },
    { { 2, 0 }, { 1, 1 }, { 2, 1 }, { 1, 2 } },
    { { 0, 1 }, { 1, 1 }, { 1, 2 }, { 2, 2 } },
    { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 0, 2 } },
  },
  J = {
    { { 0, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } },
    { { 1, 0 }, { 2, 0 }, { 1, 1 }, { 1, 2 } },
    { { 0, 1 }, { 1, 1 }, { 2, 1 }, { 2, 2 } },
    { { 1, 0 }, { 1, 1 }, { 0, 2 }, { 1, 2 } },
  },
  L = {
    { { 2, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } },
    { { 1, 0 }, { 1, 1 }, { 1, 2 }, { 2, 2 } },
    { { 0, 1 }, { 1, 1 }, { 2, 1 }, { 0, 2 } },
    { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 1, 2 } },
  },
}

local ORDER = { "I", "O", "T", "S", "Z", "J", "L" }
local SPAWN_X = { I = 4, O = 5, T = 4, S = 4, Z = 4, J = 4, L = 4 }

local TINT = {
  I = { colors.cyan, colors.lightBlue },
  O = { colors.yellow, colors.white },
  T = { colors.purple, colors.magenta },
  S = { colors.green, colors.lime },
  Z = { colors.red, colors.orange },
  J = { colors.blue, colors.lightBlue },
  L = { colors.orange, colors.yellow },
}

-- SRS wall kicks, converted to a y-down grid (positive dy moves down).
local KICKS = {
  ["0>1"] = { { 0, 0 }, { -1, 0 }, { -1, -1 }, { 0, 2 }, { -1, 2 } },
  ["1>0"] = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, -2 }, { 1, -2 } },
  ["1>2"] = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, -2 }, { 1, -2 } },
  ["2>1"] = { { 0, 0 }, { -1, 0 }, { -1, -1 }, { 0, 2 }, { -1, 2 } },
  ["2>3"] = { { 0, 0 }, { 1, 0 }, { 1, -1 }, { 0, 2 }, { 1, 2 } },
  ["3>2"] = { { 0, 0 }, { -1, 0 }, { -1, 1 }, { 0, -2 }, { -1, -2 } },
  ["3>0"] = { { 0, 0 }, { -1, 0 }, { -1, 1 }, { 0, -2 }, { -1, -2 } },
  ["0>3"] = { { 0, 0 }, { 1, 0 }, { 1, -1 }, { 0, 2 }, { 1, 2 } },
}

local KICKS_I = {
  ["0>1"] = { { 0, 0 }, { -2, 0 }, { 1, 0 }, { -2, 1 }, { 1, -2 } },
  ["1>0"] = { { 0, 0 }, { 2, 0 }, { -1, 0 }, { 2, -1 }, { -1, 2 } },
  ["1>2"] = { { 0, 0 }, { -1, 0 }, { 2, 0 }, { -1, -2 }, { 2, 1 } },
  ["2>1"] = { { 0, 0 }, { 1, 0 }, { -2, 0 }, { 1, 2 }, { -2, -1 } },
  ["2>3"] = { { 0, 0 }, { 2, 0 }, { -1, 0 }, { 2, -1 }, { -1, 2 } },
  ["3>2"] = { { 0, 0 }, { -2, 0 }, { 1, 0 }, { -2, 1 }, { 1, -2 } },
  ["3>0"] = { { 0, 0 }, { 1, 0 }, { -2, 0 }, { 1, 2 }, { -2, -1 } },
  ["0>3"] = { { 0, 0 }, { -1, 0 }, { 2, 0 }, { -1, -2 }, { 2, 1 } },
}

local GRAVITY = {
  0.800, 0.717, 0.633, 0.550, 0.467, 0.383, 0.283, 0.183, 0.133, 0.100,
  0.083, 0.083, 0.083, 0.067, 0.067, 0.067, 0.050, 0.050, 0.050, 0.033,
}

local LOCK_DELAY = 0.5
local MAX_RESETS = 15

------------------------------------------------------------------- instance
local function new(api, mode)
  local self = setmetatable({}, Game)
  self.api = api
  self.c = api.canvas.new(1, 1, gfx.W, gfx.H, colors.black)

  self.grid = {}
  for r = 1, ROWS do
    local row = {}
    for col = 1, COLS do row[col] = false end
    self.grid[r] = row
  end

  self.bag = {}
  self.queue = {}
  for _ = 1, 4 do self:pushQueue() end

  self.startLevel = (mode and mode.level) or 1
  self.level = self.startLevel
  self.score = 0
  self.lines = 0
  self.pieces = 0
  self.combo = -1
  self.backToBack = false
  self.hold = nil
  self.holdUsed = false
  self.finished = false
  self.clearRows = nil
  self.clearTimer = 0
  self.lastClear = nil
  self.tspins = 0
  self.tetrises = 0

  self.dasLeft = input.repeater(0.16, 0.04)
  self.dasRight = input.repeater(0.16, 0.04)
  self.softTimer = 0

  self:spawn()
  return self
end

------------------------------------------------------------------ 7-bag
function Game:pushQueue()
  if #self.bag == 0 then
    for i = 1, #ORDER do self.bag[i] = ORDER[i] end
    for i = #self.bag, 2, -1 do
      local j = math.random(1, i)
      self.bag[i], self.bag[j] = self.bag[j], self.bag[i]
    end
  end
  self.queue[#self.queue + 1] = table.remove(self.bag)
end

------------------------------------------------------------------ geometry
--- Compact score so it always fits the 29px side panel.
local function shortNumber(n)
  n = floor(n)
  if n < 100000 then return tostring(n) end
  return floor(n / 1000) .. "K"
end

--- The four {x, y} cell offsets of a piece in a given rotation.
function Game:shape(kind, rot)
  return SHAPES[kind][rot + 1]
end

function Game:fits(kind, rot, px, py)
  local shape = SHAPES[kind][rot + 1]
  for i = 1, 4 do
    local x = px + shape[i][1]
    local y = py + shape[i][2]
    if x < 1 or x > COLS or y > ROWS then return false end
    if y >= 1 and self.grid[y][x] then return false end
  end
  return true
end

function Game:spawn(kind)
  self.kind = kind or table.remove(self.queue, 1)
  if not kind then self:pushQueue() end
  self.rot = 0
  self.px = SPAWN_X[self.kind]
  self.py = 1
  self.gravity = 0
  self.lockTimer = 0
  self.lockResets = 0
  self.lowest = self.py
  self.lastMoveWasRotation = false
  self.pieces = self.pieces + 1

  if not self:fits(self.kind, 0, self.px, self.py) then
    -- try nudging up into the hidden rows before declaring topout
    if self:fits(self.kind, 0, self.px, self.py - 1) then
      self.py = self.py - 1
    else
      self.finished = true
      audio.play("explode")
    end
  end
end

------------------------------------------------------------------- actions
function Game:tryMove(dx, dy)
  if self.finished or self.clearRows then return false end
  if self:fits(self.kind, self.rot, self.px + dx, self.py + dy) then
    self.px = self.px + dx
    self.py = self.py + dy
    self.lastMoveWasRotation = false
    if self.py > self.lowest then
      self.lowest = self.py
      self.lockResets = 0
      self.lockTimer = 0
    elseif dx ~= 0 and self:grounded() and self.lockResets < MAX_RESETS then
      self.lockResets = self.lockResets + 1
      self.lockTimer = 0
    end
    return true
  end
  return false
end

function Game:rotate(dir)
  if self.finished or self.clearRows then return false end
  local from = self.rot
  local to = (from + dir) % 4
  if self.kind == "O" then
    self.rot = to
    return true
  end
  local table_ = (self.kind == "I") and KICKS_I or KICKS
  local kicks = table_[from .. ">" .. to]
  if not kicks then return false end
  for i = 1, #kicks do
    local dx, dy = kicks[i][1], kicks[i][2]
    if self:fits(self.kind, to, self.px + dx, self.py + dy) then
      self.rot = to
      self.px = self.px + dx
      self.py = self.py + dy
      self.lastMoveWasRotation = true
      self.lastKick = i
      if self.py > self.lowest then
        self.lowest = self.py
        self.lockResets = 0
        self.lockTimer = 0
      elseif self:grounded() and self.lockResets < MAX_RESETS then
        self.lockResets = self.lockResets + 1
        self.lockTimer = 0
      end
      audio.play("blip")
      return true
    end
  end
  audio.play("deny")
  return false
end

function Game:grounded()
  return not self:fits(self.kind, self.rot, self.px, self.py + 1)
end

function Game:ghostY()
  local y = self.py
  while self:fits(self.kind, self.rot, self.px, y + 1) do y = y + 1 end
  return y
end

function Game:swapHold()
  if self.holdUsed or self.finished or self.clearRows then
    audio.play("deny")
    return
  end
  local previous = self.hold
  self.hold = self.kind
  self.holdUsed = true
  if previous then
    self:spawn(previous)
  else
    self:spawn()
  end
  audio.play("select")
end

function Game:hardDrop()
  if self.finished or self.clearRows then return end
  local target = self:ghostY()
  local dist = target - self.py
  self.py = target
  self.score = self.score + dist * 2
  self.lastMoveWasRotation = false
  self:lock()
end

--------------------------------------------------------------------- t-spin
local CORNERS = { { 0, 0 }, { 2, 0 }, { 0, 2 }, { 2, 2 } }

function Game:detectTSpin()
  if self.kind ~= "T" or not self.lastMoveWasRotation then return false, false end
  local filled = 0
  for i = 1, 4 do
    local x = self.px + CORNERS[i][1]
    local y = self.py + CORNERS[i][2]
    if x < 1 or x > COLS or y > ROWS then
      filled = filled + 1
    elseif y >= 1 and self.grid[y][x] then
      filled = filled + 1
    end
  end
  if filled < 3 then return false, false end
  -- the two corners in front of the T face depend on its rotation
  local FRONT = {
    [0] = { { 0, 0 }, { 2, 0 } },
    [1] = { { 2, 0 }, { 2, 2 } },
    [2] = { { 0, 2 }, { 2, 2 } },
    [3] = { { 0, 0 }, { 0, 2 } },
  }
  local front = 0
  for _, off in ipairs(FRONT[self.rot]) do
    local x, y = self.px + off[1], self.py + off[2]
    if x < 1 or x > COLS or y > ROWS then
      front = front + 1
    elseif y >= 1 and self.grid[y][x] then
      front = front + 1
    end
  end
  local mini = (front < 2) and (self.lastKick ~= 5)
  return true, mini
end

---------------------------------------------------------------------- lock
function Game:lock()
  local tspin, mini = self:detectTSpin()
  local shape = SHAPES[self.kind][self.rot + 1]
  local topOut = true
  for i = 1, 4 do
    local x = self.px + shape[i][1]
    local y = self.py + shape[i][2]
    if y >= 1 and y <= ROWS and x >= 1 and x <= COLS then
      self.grid[y][x] = self.kind
      if y > HIDDEN then topOut = false end
    end
  end

  local full = {}
  for y = 1, ROWS do
    local complete = true
    for x = 1, COLS do
      if not self.grid[y][x] then complete = false break end
    end
    if complete then full[#full + 1] = y end
  end

  local n = #full
  local gained = 0
  local label = nil

  if tspin then
    self.tspins = self.tspins + 1
    if mini then
      gained = (n == 0 and 100) or (n == 1 and 200) or 400
      label = n > 0 and "T-SPIN MINI" or "T-SPIN"
    else
      gained = (n == 0 and 400) or (n == 1 and 800) or (n == 2 and 1200) or 1600
      label = "T-SPIN"
    end
  elseif n > 0 then
    gained = ({ 100, 300, 500, 800 })[n]
    if n == 4 then
      label = "TETRIS"
      self.tetrises = self.tetrises + 1
    end
  end

  local difficult = (n == 4) or (tspin and n > 0)
  if difficult and self.backToBack and gained > 0 then
    gained = floor(gained * 1.5)
    if label then label = "B2B " .. label end
  end
  if n > 0 or tspin then
    self.backToBack = difficult
  end

  if n > 0 then
    self.combo = self.combo + 1
    if self.combo > 0 then gained = gained + 50 * self.combo end
  else
    self.combo = -1
  end

  self.score = self.score + gained * self.level

  if n > 0 then
    self.clearRows = full
    self.clearTimer = 0.24
    self.lastClear = label or (n .. (n == 1 and " LINE" or " LINES"))
    audio.play(n == 4 and "clear" or "eat", n == 4 and 0 or -4)
  else
    audio.play("lock")
    if topOut then
      self.finished = true
      audio.play("explode")
      return
    end
    self.holdUsed = false
    self:spawn()
  end
end

function Game:collapse()
  local rows = self.clearRows
  self.clearRows = nil
  for i = #rows, 1, -1 do
    table.remove(self.grid, rows[i])
  end
  for _ = 1, #rows do
    local row = {}
    for x = 1, COLS do row[x] = false end
    table.insert(self.grid, 1, row)
  end

  self.lines = self.lines + #rows
  local newLevel = self.startLevel + floor(self.lines / 10)
  if newLevel > self.level then
    self.level = newLevel
    audio.play("levelup")
  end
  self.holdUsed = false
  self:spawn()
end

-------------------------------------------------------------------- update
function Game:gravityInterval()
  local i = self.level
  if i < 1 then i = 1 end
  if i > #GRAVITY then
    return math.max(0.017, 0.033 - (i - #GRAVITY) * 0.002)
  end
  return GRAVITY[i]
end

function Game:onKey(code, held)
  if held then return end
  if code == keys.up or code == keys.x or code == keys.w then
    self:rotate(1)
  elseif code == keys.z then
    self:rotate(-1)
  elseif code == keys.space then
    self:hardDrop()
  elseif code == keys.c or code == keys.leftShift or code == keys.rightShift then
    self:swapHold()
  end
end

function Game:update(dt)
  if self.finished then return end

  if self.clearRows then
    self.clearTimer = self.clearTimer - dt
    if self.clearTimer <= 0 then self:collapse() end
    return
  end

  local steps = self.dasLeft:update(input.down(keys.left, keys.a), dt)
  for _ = 1, steps do
    if self:tryMove(-1, 0) then audio.play("move") end
  end
  steps = self.dasRight:update(input.down(keys.right, keys.d), dt)
  for _ = 1, steps do
    if self:tryMove(1, 0) then audio.play("move") end
  end

  local soft = input.down(keys.down, keys.s)
  local interval = self:gravityInterval()
  if soft then
    local fast = 0.033
    if fast < interval then interval = fast end
  end

  self.gravity = self.gravity + dt
  local guard = 0
  while self.gravity >= interval and guard < 24 do
    self.gravity = self.gravity - interval
    guard = guard + 1
    if self:tryMove(0, 1) then
      if soft then self.score = self.score + 1 end
    else
      break
    end
  end

  if self:grounded() then
    self.lockTimer = self.lockTimer + dt
    if self.lockTimer >= LOCK_DELAY then
      self:lock()
    end
  else
    self.lockTimer = 0
  end
end

---------------------------------------------------------------------- draw
local function drawBlock(c, px, py, kind, style)
  local tint = TINT[kind]
  if style == "ghost" then
    c:fill(px, py, BW, BH, tint[1])
    c:fill(px + 1, py + 1, BW - 2, 1, colors.black)
  elseif style == "flash" then
    c:fill(px, py, BW, BH, colors.white)
  else
    c:fill(px, py, BW, BH, tint[1])
    c:fill(px, py, BW, 1, tint[2])
  end
end

local function wellPos(col, row)
  return WELL_X + (col - 1) * BW, WELL_Y + (row - HIDDEN - 1) * BH
end

--- Draw a piece into a preview box, centred.
local function drawPreview(c, kind, boxX, boxY, boxW, boxH)
  local shape = SHAPES[kind][1]
  local minX, maxX, minY, maxY = 9, -9, 9, -9
  for i = 1, 4 do
    local x, y = shape[i][1], shape[i][2]
    if x < minX then minX = x end
    if x > maxX then maxX = x end
    if y < minY then minY = y end
    if y > maxY then maxY = y end
  end
  local w = (maxX - minX + 1) * BW
  local h = (maxY - minY + 1) * BH
  local ox = boxX + floor((boxW - w) / 2)
  local oy = boxY + floor((boxH - h) / 2)
  for i = 1, 4 do
    drawBlock(c, ox + (shape[i][1] - minX) * BW, oy + (shape[i][2] - minY) * BH, kind)
  end
end

function Game:draw()
  local c = self.c
  c:clear(colors.black)

  -- well chrome
  c:fill(WELL_X - 2, WELL_Y, 2, VISIBLE * BH + 3, colors.gray)
  c:fill(WELL_X + COLS * BW, WELL_Y, 2, VISIBLE * BH + 3, colors.gray)
  c:fill(WELL_X - 2, WELL_Y + VISIBLE * BH, COLS * BW + 4, 3, colors.gray)

  -- settled blocks
  local flashing = nil
  if self.clearRows then
    flashing = {}
    for _, r in ipairs(self.clearRows) do flashing[r] = true end
  end
  for r = HIDDEN + 1, ROWS do
    local row = self.grid[r]
    for col = 1, COLS do
      local kind = row[col]
      if kind then
        local px, py = wellPos(col, r)
        drawBlock(c, px, py, kind, flashing and flashing[r] and "flash" or nil)
      end
    end
  end

  if not self.clearRows and not self.finished then
    -- ghost
    local gy = self:ghostY()
    local shape = SHAPES[self.kind][self.rot + 1]
    if gy ~= self.py then
      for i = 1, 4 do
        local x = self.px + shape[i][1]
        local y = gy + shape[i][2]
        if y > HIDDEN then
          local px, py = wellPos(x, y)
          drawBlock(c, px, py, self.kind, "ghost")
        end
      end
    end
    -- active piece
    for i = 1, 4 do
      local x = self.px + shape[i][1]
      local y = self.py + shape[i][2]
      if y > HIDDEN then
        local px, py = wellPos(x, y)
        drawBlock(c, px, py, self.kind)
      end
    end
  end

  -- Panel text sits on the 3-pixel character grid (y = 3k+1) with six
  -- pixels between baselines, so no two lines share a character cell.
  -- left panel
  font.draw(c, 2, 1, "HOLD", colors.lightGray, 1, 1)
  c:box(2, 7, 27, 11, self.holdUsed and colors.gray or colors.lightGray)
  if self.hold then
    drawPreview(c, self.hold, 3, 8, 25, 9)
  end
  font.draw(c, 2, 22, "SCORE", colors.lightGray, 1, 1)
  font.draw(c, 2, 28, shortNumber(self.score), colors.white, 1, 1)
  font.draw(c, 2, 37, "LEVEL", colors.lightGray, 1, 1)
  font.draw(c, 2, 43, tostring(self.level), colors.yellow, 1, 1)
  -- progress towards the next level
  local into = self.lines % 10
  c:box(2, 52, 27, 5, colors.gray)
  if into > 0 then c:fill(3, 53, floor(into * 25 / 10), 3, colors.lime) end

  -- right panel
  font.draw(c, 76, 1, "NEXT", colors.lightGray, 1, 1)
  for i = 1, 3 do
    local kind = self.queue[i]
    local boxY = 7 + (i - 1) * 12
    c:box(75, boxY, 27, 11, colors.gray)
    if kind then drawPreview(c, kind, 76, boxY + 1, 25, 9) end
  end
  font.draw(c, 76, 43, "LINES", colors.lightGray, 1, 1)
  font.draw(c, 76, 49, tostring(self.lines), colors.lime, 1, 1)

  -- clear banner
  if self.lastClear and self.clearRows then
    local text = self.lastClear
    local w = font.width(text, 1, 1)
    local bx = WELL_X + floor((COLS * BW - w) / 2)
    c:fill(bx - 3, 24, w + 6, 9, colors.black)
    font.draw(c, bx, 26, text, colors.yellow, 1, 1)
  end

  c:render()
end

function Game:summary()
  return {
    { "Lines", self.lines },
    { "Level", self.level },
    { "Tetrises", self.tetrises },
    { "T-spins", self.tspins },
  }
end

---------------------------------------------------------------------- cover
local COVER_ORDER = { "T", "L", "S", "I", "Z", "J", "O" }

local function cover(c, t)
  c:clear(colors.black)
  c:fill(1, 1, c.w, c.h, colors.black)
  for i = 1, 7 do
    local kind = COVER_ORDER[i]
    local speed = 9 + i * 1.7
    local y = ((t * speed + i * 9) % (c.h + 14)) - 12
    local x = 2 + (i - 1) * 8
    local shape = SHAPES[kind][((floor(t * 0.9) + i) % 4) + 1]
    for j = 1, 4 do
      local bx = x + shape[j][1] * 3
      local by = floor(y) + shape[j][2] * 3
      c:fill(bx, by, 3, 3, TINT[kind][1])
      c:fill(bx, by, 3, 1, TINT[kind][2])
    end
  end
  c:fill(1, c.h - 1, c.w, 2, colors.gray)
end

----------------------------------------------------------------- definition
return {
  id = "tetris",
  name = "Tetris",
  tagline = "Stack, clear, survive",
  accent = colors.cyan,
  order = 20,
  cover = cover,
  controls = {
    { "Left / Right", "Move" },
    { "Down", "Soft drop" },
    { "Up or X", "Rotate right" },
    { "Z", "Rotate left" },
    { "Space", "Hard drop" },
    { "C or Shift", "Hold piece" },
    { "P", "Pause menu" },
  },
  modes = {
    { id = "l1", name = "Level 1", hint = "marathon", level = 1 },
    { id = "l5", name = "Level 5", hint = "brisk", level = 5 },
    { id = "l10", name = "Level 10", hint = "fast", level = 10 },
    { id = "l15", name = "Level 15", hint = "brutal", level = 15 },
  },
  trophies = {
    { id = "tetris_four", name = "Four At Once", desc = "Clear four rows at once",
      test = function(g) return g.tetrises >= 1 end },
    { id = "tetris_spin", name = "Spin Doctor", desc = "Land a T-spin",
      test = function(g) return g.tspins >= 1 end },
    { id = "tetris_l10", name = "Speed Freak", desc = "Reach level 10",
      test = function(g) return g.level >= 10 end },
    { id = "tetris_100", name = "Century Stack", desc = "Clear 100 lines in one game",
      test = function(g) return g.lines >= 100 end },
  },
  new = new,
}
