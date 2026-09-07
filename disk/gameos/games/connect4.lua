--[[ Connect Four -- drop discs, make a line of four.

  The computer runs a real alpha-beta search over the standard four-in-a-row
  window heuristic. Difficulty is search depth plus a chance of picking the
  second best move, so an easy opponent plays plausibly rather than randomly.
]]

local req = ...
local gfx = req("lib.gfx")
local audio = req("lib.audio")

local floor = math.floor
local max, min = math.max, math.min

local COLS, ROWS = 7, 6
local CELL_W, CELL_H = 6, 2
local STRIDE = 7
local BOARD_X, BOARD_Y = 2, 4

local HUMAN, CPU = 1, 2

local Game = {}
Game.__index = Game

-- Inset top and bottom: a cell is only six sub-pixels tall, so without the
-- margin vertically adjacent discs merge into one solid column of colour.
local DISC = gfx.makeGlyph({
  "............",
  "...######...",
  ".##########.",
  ".##########.",
  "...######...",
  "............",
})

local DISC_COLOUR = { [HUMAN] = colors.red, [CPU] = colors.yellow }

------------------------------------------------------------------ board maths
local function idx(col, row) return (row - 1) * COLS + col end

--- Every line of four on the board, precomputed once.
local LINES = {}
do
  local DIRS = { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 1, -1 } }
  for row = 1, ROWS do
    for col = 1, COLS do
      for _, d in ipairs(DIRS) do
        local cells = {}
        local ok = true
        for step = 0, 3 do
          local cx = col + d[1] * step
          local cy = row + d[2] * step
          if cx < 1 or cx > COLS or cy < 1 or cy > ROWS then
            ok = false
            break
          end
          cells[step + 1] = idx(cx, cy)
        end
        if ok then LINES[#LINES + 1] = cells end
      end
    end
  end
end

--- Lines grouped by the cells they pass through, so a move can be checked
--- against ~13 lines instead of all 69. That is the difference between the
--- search being comfortable and being far too slow on a real computer.
local LINES_AT = {}
for i = 1, COLS * ROWS do LINES_AT[i] = {} end
for i = 1, #LINES do
  local line = LINES[i]
  for j = 1, 4 do
    local at = LINES_AT[line[j]]
    at[#at + 1] = line
  end
end

local function winnerAt(board)
  for i = 1, #LINES do
    local line = LINES[i]
    local first = board[line[1]]
    if first ~= 0 and board[line[2]] == first
       and board[line[3]] == first and board[line[4]] == first then
      return first, line
    end
  end
  return nil
end

--- Did the disc just played at `cell` complete a four?
local function wonFrom(board, cell)
  local at = LINES_AT[cell]
  local who = board[cell]
  for i = 1, #at do
    local line = at[i]
    if board[line[1]] == who and board[line[2]] == who
       and board[line[3]] == who and board[line[4]] == who then
      return true
    end
  end
  return false
end

-- hoisted: evaluate() runs at every leaf, so it must not allocate
local MINE_WORTH = { 1, 12, 90, 100000 }
local THEIRS_WORTH = { 1, 14, 120, 100000 }

--- Positive favours `me`.
local function evaluate(board, me)
  local them = (me == HUMAN) and CPU or HUMAN
  local total = 0
  for i = 1, #LINES do
    local line = LINES[i]
    local mine, theirs = 0, 0
    for j = 1, 4 do
      local v = board[line[j]]
      if v == me then mine = mine + 1
      elseif v == them then theirs = theirs + 1 end
    end
    if mine > 0 and theirs == 0 then
      total = total + MINE_WORTH[mine]
    elseif theirs > 0 and mine == 0 then
      total = total - THEIRS_WORTH[theirs]
    end
  end
  -- the middle column is worth more than the edges
  for row = 1, ROWS do
    local v = board[idx(4, row)]
    if v == me then total = total + 6 elseif v ~= 0 then total = total - 6 end
  end
  return total
end

------------------------------------------------------------------- instance
local function new(api, mode)
  local self = setmetatable({}, Game)
  self.api = api
  self.twoPlayer = (mode and mode.twoPlayer) or false
  self.depth = (mode and mode.depth) or 4
  self.slack = (mode and mode.slack) or 0
  self.modeName = (mode and mode.name) or "Normal"

  self.board = {}
  for i = 1, COLS * ROWS do self.board[i] = 0 end
  self.heights = {}
  for c = 1, COLS do self.heights[c] = 0 end

  self.turn = HUMAN
  self.cursor = 4
  self.score = 0
  self.moves = 0
  self.finished = false
  self.won = false
  self.winLine = nil
  self.message = nil
  self.thinkTimer = 0
  self.dropAnim = nil
  self.flash = 0
  return self
end

function Game:openRow(col)
  if self.heights[col] >= ROWS then return nil end
  return ROWS - self.heights[col]
end

function Game:place(col, player)
  local row = self:openRow(col)
  if not row then
    audio.play("deny")
    return false
  end
  self.board[idx(col, row)] = player
  self.heights[col] = self.heights[col] + 1
  self.moves = self.moves + 1
  self.dropAnim = { col = col, row = row, t = 0.18 }
  audio.play("thud")

  local winner, line = winnerAt(self.board)
  if winner then
    self.winLine = line
    self.finished = true
    self.won = (winner == HUMAN) or self.twoPlayer
    self.message = self.twoPlayer
      and ((winner == HUMAN) and "RED WINS" or "YELLOW WINS")
      or ((winner == HUMAN) and "YOU WIN" or "CPU WINS")
    local speed = max(0, 42 - self.moves) * 20
    if self.twoPlayer then
      self.score = 400 + speed
    elseif winner == HUMAN then
      -- beating a deeper search is worth more
      self.score = 1000 + speed + self.depth * 50
    else
      self.score = 0
    end
    audio.play(self.won and "win" or "gameover")
    return true
  end

  if self.moves >= COLS * ROWS then
    self.finished = true
    self.won = false
    self.message = "A DRAW"
    self.score = 250
    audio.play("levelup")
    return true
  end

  self.turn = (player == HUMAN) and CPU or HUMAN
  if not self.twoPlayer and self.turn == CPU then
    self.thinkTimer = 0.45
  end
  return true
end

--------------------------------------------------------------------- search
-- searching the middle first prunes far more
local ORDER = { 4, 3, 5, 2, 6, 1, 7 }

--- Alpha-beta over drop columns. The caller has already made a move, so the
--- terminal test only has to look at lines through that cell.
---
--- `budget` is a safety net, not a working limit: measured node counts are
--- about 600 at depth 4 and 3,800 at depth 5 in the worst mid-game case, well
--- under the ceiling, because a search that runs out of budget returns static
--- evaluations and plays worse the deeper it goes.
function Game:search(board, heights, depth, alpha, beta, player, budget, lastCell)
  budget.n = budget.n - 1
  if wonFrom(board, lastCell) then
    -- whoever is NOT to move just won
    if player == CPU then return -100000 - depth end
    return 100000 + depth
  end
  if depth <= 0 or budget.n <= 0 then return evaluate(board, CPU) end

  local full = true
  for c = 1, COLS do
    if heights[c] < ROWS then full = false break end
  end
  if full then return 0 end

  local maximising = (player == CPU)
  local best = maximising and -1e9 or 1e9
  for i = 1, COLS do
    local c = ORDER[i]
    if heights[c] < ROWS then
      local row = ROWS - heights[c]
      local cell = idx(c, row)
      board[cell] = player
      heights[c] = heights[c] + 1
      local value = self:search(board, heights, depth - 1, alpha, beta,
        maximising and HUMAN or CPU, budget, cell)
      board[cell] = 0
      heights[c] = heights[c] - 1
      if maximising then
        if value > best then best = value end
        if best > alpha then alpha = best end
      else
        if value < best then best = value end
        if best < beta then beta = best end
      end
      if alpha >= beta then break end
    end
  end
  return best
end

function Game:chooseColumn()
  local budget = { n = 20000 }
  local scored = {}
  for c = 1, COLS do
    if self.heights[c] < ROWS then
      local row = ROWS - self.heights[c]
      local cell = idx(c, row)
      self.board[cell] = CPU
      self.heights[c] = self.heights[c] + 1
      local value = self:search(self.board, self.heights, self.depth - 1,
        -1e9, 1e9, HUMAN, budget, cell)
      self.board[cell] = 0
      self.heights[c] = self.heights[c] - 1
      scored[#scored + 1] = { col = c, value = value }
    end
  end
  self.lastNodes = 20000 - budget.n
  if #scored == 0 then return nil end
  table.sort(scored, function(a, b) return a.value > b.value end)

  -- An easy opponent sometimes settles for the second best line, but it must
  -- never hand over the game: skip the slack when the best move is forced, or
  -- when the alternative loses outright.
  if self.slack > 0 and #scored > 1
     and math.abs(scored[1].value) < 90000
     and scored[2].value > -90000
     and math.random() < self.slack then
    return scored[2].col
  end
  return scored[1].col
end

--------------------------------------------------------------------- input
function Game:onKey(code, held)
  if self.finished then return end
  if code == keys.left or code == keys.a then
    self.cursor = self.cursor > 1 and self.cursor - 1 or COLS
    audio.play("move")
  elseif code == keys.right or code == keys.d then
    self.cursor = self.cursor < COLS and self.cursor + 1 or 1
    audio.play("move")
  elseif not held and (code == keys.space or code == keys.enter
      or code == keys.down or code == keys.s) then
    if self.twoPlayer or self.turn == HUMAN then
      self:place(self.cursor, self.turn)
    end
  elseif code >= keys.one and code <= keys.seven then
    self.cursor = code - keys.one + 1
  end
end

function Game:onMouse(kind, btn, x, y)
  if kind ~= "mouse_click" or self.finished then return end
  local col = floor((x - BOARD_X) / STRIDE) + 1
  if col < 1 or col > COLS then return end
  self.cursor = col
  if self.twoPlayer or self.turn == HUMAN then
    self:place(col, self.turn)
  end
end

-------------------------------------------------------------------- update
function Game:update(dt)
  if self.dropAnim then
    self.dropAnim.t = self.dropAnim.t - dt
    if self.dropAnim.t <= 0 then self.dropAnim = nil end
  end
  if self.flash > 0 then self.flash = self.flash - dt end
  if self.finished then
    self.flash = (self.flash > 0) and self.flash or 0.5
    return
  end

  if not self.twoPlayer and self.turn == CPU then
    if self.thinkTimer > 0 then
      self.thinkTimer = self.thinkTimer - dt
      if self.thinkTimer <= 0 then
        local col = self:chooseColumn()
        if col then self:place(col, CPU) end
      end
    end
  end
end

---------------------------------------------------------------------- draw
function Game:draw()
  gfx.clear(colors.black)

  gfx.fill(1, 1, gfx.W, 1, colors.gray)
  if self.twoPlayer then
    gfx.text(2, 1, "RED", colors.red, colors.gray)
    gfx.text(6, 1, "vs", colors.lightGray, colors.gray)
    gfx.text(9, 1, "YELLOW", colors.yellow, colors.gray)
  else
    gfx.text(2, 1, "YOU", colors.red, colors.gray)
    gfx.text(6, 1, "vs", colors.lightGray, colors.gray)
    gfx.text(9, 1, "CPU " .. self.modeName, colors.yellow, colors.gray)
  end
  if self.finished then
    gfx.right(gfx.W - 1, 1, self.message or "", colors.white, colors.gray)
  else
    local who = self.turn == HUMAN and "RED" or "YELLOW"
    if not self.twoPlayer then who = self.turn == HUMAN and "YOUR TURN" or "THINKING" end
    gfx.right(gfx.W - 1, 1, who, DISC_COLOUR[self.turn], colors.gray)
  end

  -- drop marker above the board
  gfx.fill(1, BOARD_Y - 1, gfx.W, 1, colors.black)
  if not self.finished and (self.twoPlayer or self.turn == HUMAN) then
    local mx = BOARD_X + (self.cursor - 1) * STRIDE
    gfx.fill(mx, BOARD_Y - 1, CELL_W, 1, DISC_COLOUR[self.turn])
  end

  gfx.fill(1, BOARD_Y, gfx.W, ROWS * CELL_H, colors.blue)

  local winSet = {}
  if self.winLine then
    for _, cell in ipairs(self.winLine) do winSet[cell] = true end
  end

  for row = 1, ROWS do
    for col = 1, COLS do
      local sx = BOARD_X + (col - 1) * STRIDE
      local sy = BOARD_Y + (row - 1) * CELL_H
      local v = self.board[idx(col, row)]
      local colour = colors.black
      if v ~= 0 then colour = DISC_COLOUR[v] end
      if winSet[idx(col, row)] and floor(self.flash * 6) % 2 == 0 then
        colour = colors.white
      end
      gfx.blitGlyph(sx, sy, DISC, colour, colors.blue)
    end
  end

  gfx.rule(1, 18, gfx.W, colors.gray, colors.black)
  if self.finished then
    gfx.center(19, (self.message or "") .. " -- " .. self.moves .. " discs",
      colors.white, colors.black)
  else
    gfx.center(19, "Left/Right choose   Space drop", colors.lightGray, colors.black)
  end
end

function Game:summary()
  return {
    { "Result", self.message or "unfinished" },
    { "Discs played", self.moves },
    { "Opponent", self.twoPlayer and "human" or self.modeName },
  }
end

---------------------------------------------------------------------- cover
local function cover(c, t)
  c:clear(colors.blue)
  local cell = 9
  local ox = floor((c.w - 5 * cell) / 2)
  local oy = 1
  local drop = floor(t * 3) % 8
  for row = 1, 2 do
    for col = 1, 5 do
      local x = ox + (col - 1) * cell
      local y = oy + (row - 1) * cell
      local v = 0
      if row == 2 and col <= 4 then v = (col % 2 == 1) and 1 or 2 end
      if row == 1 and col == 3 and drop > 3 then v = 1 end
      local colour = colors.black
      if v == 1 then colour = colors.red elseif v == 2 then colour = colors.yellow end
      c:circle(x + 3, y + 3, 3, colour, true)
    end
  end
  if drop <= 3 then
    c:circle(ox + 2 * cell + 3, 1 + drop * 2, 3, colors.red, true)
  end
end

----------------------------------------------------------------- definition
return {
  id = "connect4",
  name = "Connect Four",
  tagline = "Four in a row, and a real opponent",
  accent = colors.blue,
  order = 130,
  cover = cover,
  controls = {
    { "Left / Right", "Choose a column" },
    { "1 - 7", "Jump to a column" },
    { "Space / Down", "Drop a disc" },
    { "Click", "Drop in that column" },
    { "P", "Pause menu" },
  },
  modes = {
    { id = "easy", name = "Easy", hint = "shallow, forgiving", depth = 2, slack = 0.5 },
    { id = "normal", name = "Normal", hint = "thinks ahead", depth = 4, slack = 0.15 },
    { id = "hard", name = "Hard", hint = "does not blunder", depth = 5, slack = 0 },
    { id = "two", name = "Two players", hint = "share the keyboard", twoPlayer = true },
  },
  trophies = {
    { id = "c4_win", name = "Four In A Row", desc = "Beat the computer",
      test = function(g) return g.won and not g.twoPlayer end },
    { id = "c4_hard", name = "Out-Thought It", desc = "Beat the hard computer",
      test = function(g) return g.won and not g.twoPlayer and g.depth >= 5 end },
    { id = "c4_quick", name = "Quick Work", desc = "Win in 12 discs or fewer",
      test = function(g) return g.won and not g.twoPlayer and g.moves <= 12 end },
  },
  new = new,
}
