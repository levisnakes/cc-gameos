--[[ Sokoban -- one level per run, with unlimited undo.

  Levels use the standard notation: # wall, space floor, . goal, $ box,
  * box on goal, @ player, + player on goal. Every level here has been
  machine-checked for solvability and its `par` is the optimal push count.
]]

local req = ...
local gfx = req("lib.gfx")
local audio = req("lib.audio")
local data = req("lib.data")

local floor = math.floor

local Game = {}
Game.__index = Game

-- Sprites in two sizes: fat cells (4x2 characters) for small levels, thin
-- cells (2x1) for the wide ones.
local ART = {
  big = {
    crate = gfx.makeGlyph({
      "########",
      "#......#",
      "#.####.#",
      "#.####.#",
      "#......#",
      "########",
    }),
    -- the ink is the face, not the figure, so the cell stays a solid block
    player = gfx.makeGlyph({
      "........",
      "..#..#..",
      "..#..#..",
      "........",
      "..####..",
      "........",
    }),
    goal = gfx.makeGlyph({
      "........",
      "..####..",
      "..#..#..",
      "..#..#..",
      "..####..",
      "........",
    }),
  },
  small = {
    crate = gfx.makeGlyph({
      "####",
      "#..#",
      "####",
    }),
    player = gfx.makeGlyph({
      "....",
      "#..#",
      ".##.",
    }),
    goal = gfx.makeGlyph({
      "....",
      ".##.",
      "....",
    }),
  },
}

local LEVELS = {
  { par = 2, rows = {
    "########",
    "#      #",
    "# $$   #",
    "# ..@  #",
    "#      #",
    "########",
  } },
  { par = 3, rows = {
    "#######",
    "#.    #",
    "#  $  #",
    "#   @ #",
    "#     #",
    "#######",
  } },
  { par = 6, rows = {
    "###########",
    "#         #",
    "# ##   ## #",
    "# #  $  # #",
    "# # $.$ # #",
    "# #  .  # #",
    "# ## . ## #",
    "#    @    #",
    "###########",
  } },
  { par = 8, rows = {
    "##########",
    "#        #",
    "#  ####  #",
    "#  #..#  #",
    "#  #  #  #",
    "# $    $ #",
    "#   @    #",
    "##########",
  } },
  { par = 8, rows = {
    "##########",
    "#        #",
    "#  $  $  #",
    "#   ..   #",
    "#   ..   #",
    "#  $  $  #",
    "#    @   #",
    "##########",
  } },
  { par = 9, rows = {
    "#########",
    "#       #",
    "# $ $ $ #",
    "#       #",
    "#  @    #",
    "# . . . #",
    "#########",
  } },
  { par = 10, rows = {
    "#############",
    "#           #",
    "# ######### #",
    "# #   @   # #",
    "# # $$$$$ # #",
    "# #       # #",
    "# ##.....## #",
    "#           #",
    "#############",
  } },
  { par = 12, rows = {
    "############",
    "#          #",
    "#   $$$$   #",
    "#  ##  ##  #",
    "#   ....   #",
    "#     @    #",
    "############",
  } },
  { par = 14, rows = {
    "###########",
    "#         #",
    "#  $   .  #",
    "#  $ # .  #",
    "#  $   .  #",
    "#    @    #",
    "###########",
  } },
  { par = 16, rows = {
    "##############",
    "#            #",
    "#   ......   #",
    "#  ##    ##  #",
    "#   $$$$$$   #",
    "#     @      #",
    "##############",
  } },
  { par = 18, rows = {
    "############",
    "#          #",
    "#   ....   #",
    "#   ####   #",
    "#  $ $ $ $ #",
    "#          #",
    "#    @     #",
    "############",
  } },
  { par = 24, rows = {
    "############",
    "#          #",
    "#..   $    #",
    "#..        #",
    "#     $    #",
    "#   $   $  #",
    "#     @    #",
    "############",
  } },
}

------------------------------------------------------------------ instance
local function new(api, mode)
  local self = setmetatable({}, Game)
  self.api = api
  local prog = data.progress("sokoban")
  if mode and mode.restart then
    prog.level = 1
    data.markDirty()
  end
  local index = (mode and mode.level) or prog.level or 1
  if index > #LEVELS then index = #LEVELS end
  if index < 1 then index = 1 end
  self.index = index
  self.def = LEVELS[index]
  self:load()
  self.score = 0
  self.finished = false
  self.won = false
  self.flash = 0
  return self
end

function Game:load()
  local rows = self.def.rows
  self.h = #rows
  self.w = 0
  for i = 1, self.h do
    if #rows[i] > self.w then self.w = #rows[i] end
  end
  self.walls = {}
  self.goals = {}
  self.boxes = {}
  self.goalCount = 0
  for y = 1, self.h do
    local line = rows[y]
    for x = 1, self.w do
      local ch = line:sub(x, x)
      local k = (y - 1) * self.w + x
      if ch == "#" then
        self.walls[k] = true
      elseif ch == "." or ch == "*" or ch == "+" then
        self.goals[k] = true
        self.goalCount = self.goalCount + 1
      end
      if ch == "$" or ch == "*" then self.boxes[k] = true end
      if ch == "@" or ch == "+" then self.px, self.py = x, y end
    end
  end
  self.moves = 0
  self.pushes = 0
  self.history = {}
  -- Small levels get fat cells so they fill the screen instead of huddling
  -- in the middle of it.
  self.cw = (self.w * 4 <= 50) and 4 or 2
  self.ch = (self.h * 2 <= 15) and 2 or 1
  self.ox = floor((gfx.W - self.w * self.cw) / 2) + 1
  self.oy = 3 + floor((15 - self.h * self.ch) / 2)
end

function Game:key(x, y) return (y - 1) * self.w + x end

function Game:solved()
  for k in pairs(self.goals) do
    if not self.boxes[k] then return false end
  end
  return true
end

function Game:onGoalCount()
  local n = 0
  for k in pairs(self.goals) do
    if self.boxes[k] then n = n + 1 end
  end
  return n
end

-------------------------------------------------------------------- moving
function Game:snapshot()
  local boxes = {}
  for k in pairs(self.boxes) do boxes[k] = true end
  self.history[#self.history + 1] = {
    px = self.px, py = self.py, boxes = boxes,
    moves = self.moves, pushes = self.pushes,
  }
  if #self.history > 400 then table.remove(self.history, 1) end
end

function Game:step(dx, dy)
  if self.finished then return end
  local nx, ny = self.px + dx, self.py + dy
  if nx < 1 or nx > self.w or ny < 1 or ny > self.h then return end
  local nk = self:key(nx, ny)
  if self.walls[nk] then
    audio.play("deny")
    return
  end

  if self.boxes[nk] then
    local bx, by = nx + dx, ny + dy
    if bx < 1 or bx > self.w or by < 1 or by > self.h then
      audio.play("deny")
      return
    end
    local bk = self:key(bx, by)
    if self.walls[bk] or self.boxes[bk] then
      audio.play("deny")
      return
    end
    self:snapshot()
    self.boxes[nk] = nil
    self.boxes[bk] = true
    self.pushes = self.pushes + 1
    audio.play(self.goals[bk] and "coin" or "push")
  else
    self:snapshot()
    audio.play("step")
  end

  self.px, self.py = nx, ny
  self.moves = self.moves + 1

  if self:solved() then
    self.finished = true
    self.won = true
    self.flash = 1
    local par = self.def.par > 0 and self.def.par or self.pushes
    local efficiency = math.max(0, par * 2 - self.pushes) * 20
    self.score = 500 + self.index * 100 + efficiency
    local prog = data.progress("sokoban")
    local best = prog.best or {}
    if not best[self.index] or self.moves < best[self.index] then
      best[self.index] = self.moves
    end
    prog.best = best
    prog.level = math.min(#LEVELS, self.index + 1)
    if self.index >= #LEVELS then prog.completed = true end
    data.markDirty()
    audio.play("win")
  end
end

function Game:undo()
  local prev = table.remove(self.history)
  if not prev then
    audio.play("deny")
    return
  end
  self.px, self.py = prev.px, prev.py
  self.boxes = prev.boxes
  self.moves = prev.moves
  self.pushes = prev.pushes
  audio.play("undo")
end

function Game:restart()
  self:load()
  audio.play("back")
end

--------------------------------------------------------------------- input
function Game:onKey(code, held)
  if code == keys.left or code == keys.a then
    self:step(-1, 0)
  elseif code == keys.right or code == keys.d then
    self:step(1, 0)
  elseif code == keys.up or code == keys.w then
    self:step(0, -1)
  elseif code == keys.down or code == keys.s then
    self:step(0, 1)
  elseif code == keys.u and not held then
    self:undo()
  elseif code == keys.r and not held then
    self:restart()
  end
end

function Game:update(dt)
  if self.flash > 0 then self.flash = self.flash - dt end
end

---------------------------------------------------------------------- draw
function Game:draw()
  gfx.clear(colors.black)

  gfx.fill(1, 1, gfx.W, 1, colors.gray)
  gfx.text(2, 1, "LEVEL", colors.lightGray, colors.gray)
  gfx.text(8, 1, self.index .. "/" .. #LEVELS, colors.white, colors.gray)
  gfx.center(1, "MOVES " .. self.moves .. "   PUSH " .. self.pushes, colors.lightGray, colors.gray)
  gfx.right(gfx.W - 1, 1, self:onGoalCount() .. "/" .. self.goalCount, colors.lime, colors.gray)

  local cw, ch = self.cw, self.ch
  local art = (cw >= 4) and ART.big or ART.small
  for y = 1, self.h do
    local sy = self.oy + (y - 1) * ch
    for x = 1, self.w do
      local sx = self.ox + (x - 1) * cw
      local k = self:key(x, y)

      if self.walls[k] then
        gfx.fill(sx, sy, cw, ch, colors.lightGray)
        -- light only the exposed top of a wall run, not every wall cell
        if ch > 1 and not self.walls[self:key(x, y - 1)] then
          gfx.fill(sx, sy, cw, 1, colors.white)
        end
      elseif self.boxes[k] then
        local onGoal = self.goals[k]
        gfx.blitGlyph(sx, sy, art.crate,
          onGoal and colors.green or colors.brown,
          onGoal and colors.lime or colors.orange)
      elseif self.px == x and self.py == y then
        gfx.blitGlyph(sx, sy, art.player, colors.black,
          self.goals[k] and colors.lightBlue or colors.cyan)
      elseif self.goals[k] then
        gfx.blitGlyph(sx, sy, art.goal, colors.magenta, colors.gray)
      else
        gfx.fill(sx, sy, cw, ch, colors.black)
      end
    end
  end

  gfx.rule(1, 18, gfx.W, colors.gray, colors.black)
  if self.won then
    gfx.center(19, "Solved in " .. self.moves .. " moves!", colors.lime, colors.black)
  else
    local par = self.def.par > 0 and ("   par " .. self.def.par .. " pushes") or ""
    gfx.center(19, "U undo   R restart" .. par, colors.lightGray, colors.black)
  end
end

function Game:summary()
  local prog = data.progress("sokoban")
  local best = (prog.best or {})[self.index]
  return {
    { "Level", self.index .. " of " .. #LEVELS },
    { "Moves", self.moves },
    { "Pushes", self.pushes .. (self.def.par > 0 and (" / " .. self.def.par) or "") },
    { "Your best", best and (best .. " moves") or "--" },
  }
end

------------------------------------------------------------------ configure
--- Asked by the runtime before a session starts, so the level picker never
--- runs inside new().
local function configure(api, mode)
  if not (mode and mode.select) then return mode end
  local prog = data.progress("sokoban")
  local best = prog.best or {}
  local items = {}
  for i, level in ipairs(LEVELS) do
    items[i] = {
      label = "Level " .. i,
      hint = best[i] and (best[i] .. " moves") or ("par " .. level.par),
    }
  end
  local pick = api.ui.picker({
    title = " Choose a level ",
    items = items,
    accent = colors.orange,
    default = math.min(#LEVELS, prog.level or 1),
    rows = 10,
    width = 30,
    footer = "hint shows your best, or par",
  })
  if pick == 0 then return false end
  return { id = "select", name = "Level " .. pick, level = pick }
end

---------------------------------------------------------------------- cover
local COVER = {
  "########",
  "#  .   #",
  "# $ #  #",
  "#  @   #",
  "########",
}

local function cover(c, t)
  c:clear(colors.black)
  local cell = 4
  local ox = floor((c.w - 8 * cell) / 2)
  local oy = floor((c.h - 5 * cell) / 2)
  local bob = (floor(t * 2) % 2)
  for y = 1, 5 do
    for x = 1, 8 do
      local ch = COVER[y]:sub(x, x)
      local px = ox + (x - 1) * cell
      local py = oy + (y - 1) * cell
      if ch == "#" then
        c:fill(px, py, cell, cell, colors.lightGray)
        c:fill(px, py, cell, 1, colors.white)
      elseif ch == "." then
        c:fill(px + 1, py + 1, cell - 2, cell - 2, colors.magenta)
      elseif ch == "$" then
        c:fill(px + bob, py, cell, cell, colors.orange)
        c:box(px + bob, py, cell, cell, colors.brown)
      elseif ch == "@" then
        c:fill(px + bob, py, cell, cell, colors.cyan)
        c:set(px + bob + 1, py + 1, colors.black)
        c:set(px + bob + 2, py + 1, colors.black)
      end
    end
  end
end

----------------------------------------------------------------- definition
return {
  id = "sokoban",
  name = "Sokoban",
  tagline = "Push every crate home",
  accent = colors.orange,
  order = 70,
  cover = cover,
  scoreLabel = "BEST",
  controls = {
    { "Arrows / WASD", "Walk / push" },
    { "U", "Undo" },
    { "R", "Restart level" },
    { "P", "Pause menu" },
  },
  configure = configure,
  modes = {
    { id = "continue", name = "Continue", hint = "next level" },
    { id = "select", name = "Level select", hint = "pick one", select = true },
    { id = "restart", name = "Start over", hint = "level 1", restart = true },
  },
  trophies = {
    { id = "sok_par", name = "Efficient", desc = "Solve a level in par pushes",
      test = function(g) return g.won and g.def.par > 0 and g.pushes <= g.def.par end },
    { id = "sok_l7", name = "Warehouse Hand", desc = "Reach level 7",
      test = function(g) return g.index >= 7 end },
    { id = "sok_all", name = "All Packed Away", desc = "Finish all twelve levels",
      test = function() return data.progress("sokoban").completed == true end },
  },
  new = new,
}
