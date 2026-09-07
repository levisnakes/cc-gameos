--[[ Minesweeper -- character-cell grid, two cells per square.

  Mines are laid after the first click so the opening move is always safe and
  always opens a region. Supports chording: activating a satisfied number
  clears its remaining neighbours.
]]

local req = ...
local gfx = req("lib.gfx")
local audio = req("lib.audio")

local floor = math.floor
local max, min = math.max, math.min

local Game = {}
Game.__index = Game

local NUMBER_COLOUR = {
  colors.lightBlue, colors.lime, colors.red, colors.purple,
  colors.orange, colors.cyan, colors.white, colors.lightGray,
}

local GRID_TOP = 3
local GRID_ROWS = 16

-- 4x3 sub-pixel sprites, one per two-character cell
local MINE = gfx.makeGlyph({
  ".##.",
  "####",
  ".##.",
})
local FLAG = gfx.makeGlyph({
  ".###",
  ".##.",
  ".#..",
})
local WRONG = gfx.makeGlyph({
  "#..#",
  ".##.",
  "#..#",
})

------------------------------------------------------------------ instance
local function new(api, mode)
  local self = setmetatable({}, Game)
  self.api = api
  self.cols = (mode and mode.cols) or 9
  self.rows = (mode and mode.rows) or 9
  self.mines = (mode and mode.mines) or 10
  self.levelName = (mode and mode.name) or "Beginner"
  self.bonus = (mode and mode.bonus) or 500

  self.ox = floor((gfx.W - self.cols * 2) / 2) + 1
  self.oy = GRID_TOP + floor((GRID_ROWS - self.rows) / 2)

  self.cells = {}
  for i = 1, self.cols * self.rows do
    self.cells[i] = { mine = false, adj = 0, shown = false, flag = false }
  end

  self.cursorX, self.cursorY = floor(self.cols / 2) + 1, floor(self.rows / 2) + 1
  self.started = false
  self.time = 0
  self.flags = 0
  self.revealed = 0
  self.score = 0
  self.finished = false
  self.won = false
  self.blast = nil
  self.hint = "Space reveal   F flag   C chord"
  return self
end

function Game:at(x, y)
  if x < 1 or x > self.cols or y < 1 or y > self.rows then return nil end
  return self.cells[(y - 1) * self.cols + x]
end

function Game:neighbours(x, y, fn)
  for dy = -1, 1 do
    for dx = -1, 1 do
      if dx ~= 0 or dy ~= 0 then
        local cell = self:at(x + dx, y + dy)
        if cell then fn(cell, x + dx, y + dy) end
      end
    end
  end
end

--- Lay mines, keeping the first click and its neighbours clear.
function Game:layMines(safeX, safeY)
  local spots = {}
  for y = 1, self.rows do
    for x = 1, self.cols do
      if math.abs(x - safeX) > 1 or math.abs(y - safeY) > 1 then
        spots[#spots + 1] = (y - 1) * self.cols + x
      end
    end
  end
  for i = #spots, 2, -1 do
    local j = math.random(1, i)
    spots[i], spots[j] = spots[j], spots[i]
  end
  local placed = min(self.mines, #spots)
  for i = 1, placed do
    self.cells[spots[i]].mine = true
  end
  self.mines = placed

  for y = 1, self.rows do
    for x = 1, self.cols do
      local cell = self:at(x, y)
      local n = 0
      self:neighbours(x, y, function(other) if other.mine then n = n + 1 end end)
      cell.adj = n
    end
  end
  self.started = true
end

--------------------------------------------------------------------- moves
function Game:flood(x, y)
  -- iterative so a large board cannot blow the Lua stack
  local stack = { { x, y } }
  while #stack > 0 do
    local pos = table.remove(stack)
    local cx, cy = pos[1], pos[2]
    local cell = self:at(cx, cy)
    if cell and not cell.shown and not cell.flag then
      cell.shown = true
      self.revealed = self.revealed + 1
      if cell.adj == 0 and not cell.mine then
        for dy = -1, 1 do
          for dx = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
              stack[#stack + 1] = { cx + dx, cy + dy }
            end
          end
        end
      end
    end
  end
end

function Game:reveal(x, y)
  if self.finished then return end
  local cell = self:at(x, y)
  if not cell or cell.shown or cell.flag then return end
  if not self.started then self:layMines(x, y) end
  if cell.mine then
    cell.shown = true
    self.blast = { x, y }
    self:lose()
    return
  end
  self:flood(x, y)
  audio.play("reveal")
  self:checkWin()
end

function Game:toggleFlag(x, y)
  if self.finished then return end
  local cell = self:at(x, y)
  if not cell or cell.shown then return end
  cell.flag = not cell.flag
  self.flags = self.flags + (cell.flag and 1 or -1)
  audio.play("flag")
end

function Game:chord(x, y)
  if self.finished then return end
  local cell = self:at(x, y)
  if not cell or not cell.shown or cell.adj == 0 then return end
  local flags = 0
  self:neighbours(x, y, function(other) if other.flag then flags = flags + 1 end end)
  if flags ~= cell.adj then
    audio.play("deny")
    return
  end
  local blown = false
  self:neighbours(x, y, function(other, nx, ny)
    if not other.flag and not other.shown then
      if other.mine then
        other.shown = true
        self.blast = { nx, ny }
        blown = true
      else
        self:flood(nx, ny)
      end
    end
  end)
  if blown then
    self:lose()
  else
    audio.play("reveal")
    self:checkWin()
  end
end

function Game:checkWin()
  local safe = self.cols * self.rows - self.mines
  if self.revealed >= safe then
    self.won = true
    self.finished = true
    for i = 1, #self.cells do
      local cell = self.cells[i]
      if cell.mine and not cell.flag then
        cell.flag = true
        self.flags = self.flags + 1
      end
    end
    local speed = max(0, 600 - floor(self.time)) * 5
    self.score = self.revealed * 10 + self.bonus + speed
    audio.play("win")
  else
    self.score = self.revealed * 10
  end
end

function Game:lose()
  self.finished = true
  self.won = false
  self.score = self.revealed * 10
  for i = 1, #self.cells do
    local cell = self.cells[i]
    if cell.mine then cell.shown = true end
  end
  audio.play("explode")
end

--------------------------------------------------------------------- input
function Game:onKey(code, held)
  if self.finished then return end
  if code == keys.left or code == keys.a then
    self.cursorX = max(1, self.cursorX - 1)
  elseif code == keys.right or code == keys.d then
    self.cursorX = min(self.cols, self.cursorX + 1)
  elseif code == keys.up or code == keys.w then
    self.cursorY = max(1, self.cursorY - 1)
  elseif code == keys.down or code == keys.s then
    self.cursorY = min(self.rows, self.cursorY + 1)
  elseif code == keys.space or code == keys.enter then
    local cell = self:at(self.cursorX, self.cursorY)
    if cell and cell.shown then
      self:chord(self.cursorX, self.cursorY)
    else
      self:reveal(self.cursorX, self.cursorY)
    end
  elseif code == keys.f then
    self:toggleFlag(self.cursorX, self.cursorY)
  elseif code == keys.c then
    self:chord(self.cursorX, self.cursorY)
  end
  if held then return end
end

function Game:onMouse(kind, btn, x, y)
  if kind ~= "mouse_click" or self.finished then return end
  local gx = floor((x - self.ox) / 2) + 1
  local gy = y - self.oy + 1
  if gx < 1 or gx > self.cols or gy < 1 or gy > self.rows then return end
  self.cursorX, self.cursorY = gx, gy
  local cell = self:at(gx, gy)
  if btn == 2 then
    self:toggleFlag(gx, gy)
  elseif btn == 3 then
    self:chord(gx, gy)
  elseif cell and cell.shown then
    self:chord(gx, gy)
  else
    self:reveal(gx, gy)
  end
end

-------------------------------------------------------------------- update
function Game:update(dt)
  if self.finished then return end
  if self.started then self.time = self.time + dt end
end

---------------------------------------------------------------------- draw
function Game:draw()
  gfx.clear(colors.black)

  gfx.fill(1, 1, gfx.W, 1, colors.gray)
  gfx.text(2, 1, "MINES", colors.lightGray, colors.gray)
  local left = self.mines - self.flags
  gfx.text(8, 1, string.format("%3d", left), left < 0 and colors.red or colors.white, colors.gray)
  gfx.center(1, self.levelName, colors.lightBlue, colors.gray)
  gfx.right(gfx.W - 1, 1, string.format("%3d s", floor(self.time)), colors.yellow, colors.gray)

  local BEVEL = gfx.TOP1 .. gfx.TOP2
  for y = 1, self.rows do
    local sy = self.oy + y - 1
    for x = 1, self.cols do
      local sx = self.ox + (x - 1) * 2
      local cell = self:at(x, y)
      local isCursor = (x == self.cursorX and y == self.cursorY) and not self.finished

      if cell.shown then
        if cell.mine then
          local blasted = self.blast and self.blast[1] == x and self.blast[2] == y
          local bg = blasted and colors.red or colors.gray
          gfx.blitGlyph(sx, sy, MINE, blasted and colors.white or colors.red, bg)
        else
          local bg = isCursor and colors.blue or colors.gray
          if cell.adj > 0 then
            gfx.text(sx, sy, " " .. cell.adj, NUMBER_COLOUR[cell.adj], bg)
          else
            gfx.fill(sx, sy, 2, 1, bg)
          end
        end
      elseif cell.flag then
        local bg = isCursor and colors.lightBlue or colors.lightGray
        -- after a loss, a flag on a safe square is marked as a mistake
        local wrong = self.finished and not self.won and not cell.mine
        gfx.blitGlyph(sx, sy, wrong and WRONG or FLAG, wrong and colors.black or colors.red, bg)
      else
        -- Unrevealed tiles are drawn as a bevel: the left cell carries a lit
        -- top edge, the right cell a shaded bottom edge, so the grid reads as
        -- individual raised tiles rather than one slab.
        local face = isCursor and colors.lightBlue or colors.lightGray
        local shade = isCursor and colors.blue or colors.gray
        gfx.blitStr(sx, sy, BEVEL,
          gfx.blit[colors.white] .. gfx.blit[face],
          gfx.blit[face] .. gfx.blit[shade])
      end
    end
  end

  if self.finished then
    gfx.center(19, self.won and "Cleared!" or "Boom.", self.won and colors.lime or colors.red, colors.black)
  else
    gfx.center(19, self.hint, colors.lightGray, colors.black)
  end
end

function Game:summary()
  return {
    { "Difficulty", self.levelName },
    { "Time", floor(self.time) .. "s" },
    { "Cleared", self.revealed .. "/" .. (self.cols * self.rows - self.mines) },
  }
end

---------------------------------------------------------------------- cover
local COVER_GRID = {
  "11111111111111",
  "1..21...1*1..1",
  "1.2..1F.11...1",
  "11..2..1..3..1",
  "1.1...11..1..1",
  "111111111111 1",
}

local function cover(c, t)
  c:clear(colors.black)
  local cell = 4
  local sweep = (t * 9) % 20
  for row = 1, 6 do
    local line = COVER_GRID[row]
    for col = 1, 14 do
      local ch = line:sub(col, col)
      local x = (col - 1) * cell + 1
      local y = (row - 1) * cell + 1
      local hidden = (ch == "1")
      if col > sweep then hidden = true end
      if hidden then
        c:fill(x, y, cell - 1, cell - 1, colors.lightGray)
        c:fill(x, y, cell - 1, 1, colors.white)
      else
        c:fill(x, y, cell - 1, cell - 1, colors.gray)
        if ch == "*" then
          c:fill(x + 1, y + 1, 1, 1, colors.red)
        elseif ch == "F" then
          c:fill(x + 1, y, 1, 3, colors.red)
        elseif ch ~= "." and ch ~= " " then
          local n = tonumber(ch)
          if n then c:fill(x + 1, y + 1, 1, 1, NUMBER_COLOUR[n] or colors.white) end
        end
      end
    end
  end
end

----------------------------------------------------------------- definition
return {
  id = "minesweeper",
  name = "Minesweeper",
  tagline = "Numbers, not luck",
  accent = colors.lightBlue,
  order = 50,
  cover = cover,
  controls = {
    { "Arrows / WASD", "Move cursor" },
    { "Space", "Reveal / chord" },
    { "F", "Toggle flag" },
    { "Left click", "Reveal" },
    { "Right click", "Flag" },
    { "P", "Pause menu" },
  },
  modes = {
    { id = "beginner", name = "Beginner", hint = "9x9, 10", cols = 9, rows = 9, mines = 10, bonus = 400 },
    { id = "medium", name = "Intermediate", hint = "16x16, 40", cols = 16, rows = 16, mines = 40, bonus = 1200 },
    { id = "expert", name = "Expert", hint = "24x16, 99", cols = 24, rows = 16, mines = 99, bonus = 3000 },
  },
  trophies = {
    { id = "ms_win", name = "All Clear", desc = "Clear any board",
      test = function(g) return g.won end },
    { id = "ms_fast", name = "Quick Sweep", desc = "Clear a board in under 40s",
      test = function(g) return g.won and g.time < 40 end },
    { id = "ms_expert", name = "Bomb Disposal", desc = "Clear the expert board",
      test = function(g) return g.won and g.cols >= 24 end },
  },
  new = new,
}
