-- Produces the showcase screenshots: each game driven by a competent bot to
-- an interesting moment, plus the launcher and system screens.
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
  version = "1.0.0", gfx = gfx, canvas = Canvas, font = font,
  input = input, audio = audio, data = data, ui = req("lib.ui"), require = req,
}

local function make(id, modeIdx)
  local def = req("games." .. id)
  return def, def.new(api, def.modes and def.modes[modeIdx or 1])
end

local function tap(inst, code)
  input.onKey(code, false)
  if inst.onKey then inst:onKey(code, false) end
  input.onKeyUp(code)
end

local function hold(code, down)
  if down then input.onKey(code, false) else input.onKeyUp(code) end
end

local function run(inst, frames, bot)
  for f = 1, frames do
    if bot then bot(inst, f) end
    inst:update(0.05)
    gfx.beginFrame()
    inst:draw()
    gfx.endFrame()
    input.endFrame()
    if inst.finished then break end
  end
end

local function shot(name, inst)
  gfx.beginFrame()
  inst:draw()
  gfx.endFrame()
  SHOT(name)
end

---------------------------------------------------------------------- snake
do
  local _, s = make("snake", 1)
  run(s, 420, function(inst)
    local head = inst.body[inst.head]
    local food = inst.food
    if not (head and food) then return end
    local dx, dy = food.x - head.x, food.y - head.y
    if math.abs(dx) >= math.abs(dy) and dx ~= 0 then
      inst:turn(dx > 0 and "right" or "left")
    elseif dy ~= 0 then
      inst:turn(dy > 0 and "down" or "up")
    end
  end)
  shot("snake", s)
end

--------------------------------------------------------------------- tetris
do
  local _, t = make("tetris", 1)
  local function place(inst, kind, rot, px)
    if not inst:fits(kind, rot, px, 1) then return nil end
    local py = 1
    while inst:fits(kind, rot, px, py + 1) do py = py + 1 end
    local g = {}
    for y = 1, 20 do
      local row = {}
      for x = 1, 10 do row[x] = inst.grid[y][x] and true or false end
      g[y] = row
    end
    local shape = inst:shape(kind, rot)
    for i = 1, 4 do
      local x, y = px + shape[i][1], py + shape[i][2]
      if y < 1 or y > 20 or x < 1 or x > 10 then return nil end
      g[y][x] = true
    end
    local cleared, aggregate, holes, prev, bump = 0, 0, 0, nil, 0
    for y = 1, 20 do
      local full = true
      for x = 1, 10 do if not g[y][x] then full = false break end end
      if full then cleared = cleared + 1 end
    end
    for x = 1, 10 do
      local top
      for y = 1, 20 do if g[y][x] then top = y break end end
      local height = top and (21 - top) or 0
      aggregate = aggregate + height
      if top then
        for y = top + 1, 20 do if not g[y][x] then holes = holes + 1 end end
      end
      if prev then bump = bump + math.abs(height - prev) end
      prev = height
    end
    return 0.76 * cleared - 0.51 * aggregate - 0.36 * holes - 0.18 * bump
  end
  -- deliberately mediocre: keep a stack on screen rather than clearing it all
  run(t, 700, function(inst, f)
    if f % 8 ~= 0 or inst.clearRows or inst.finished then return end
    local best, bestRot, bestX
    for rot = 0, 3 do
      for px = -2, 10 do
        local s = place(inst, inst.kind, rot, px)
        if s and (not best or s > best) then best, bestRot, bestX = s, rot, px end
      end
    end
    if not best then return end
    while inst.rot ~= bestRot do if not inst:rotate(1) then break end end
    local guard = 0
    while inst.px ~= bestX and guard < 14 do
      guard = guard + 1
      if not inst:tryMove(inst.px < bestX and 1 or -1, 0) then break end
    end
    if f % 24 ~= 0 then tap(inst, keys.space) end
  end)
  shot("tetris", t)
end

------------------------------------------------------------------- breakout
do
  local _, b = make("breakout", 2)
  run(b, 260, function(inst, f)
    local ball = inst.balls[1]
    if ball then inst.mouseTarget = ball.x - inst.paddleW / 2 + 1 end
    if f % 5 == 0 then tap(inst, keys.space) end
  end)
  shot("breakout", b)
end

-------------------------------------------------------------------- bombard
do
  -- A few turns in, so the showcase frame has a chewed-up hill rather than a
  -- pristine one.
  local def = req("games.bombard")
  local v = def.new(api, { id = "normal", cpu = "normal", tries = 30, error = 8, seed = 8899 })
  run(v, 1200, function(inst)
    if inst.phase == "aim" and inst.turn == 1 and inst.shots[1] < 4 then
      inst:fire(46 + math.random() * 16, 62 + math.random() * 14)
    end
  end)
  shot("bombard", v)
end

---------------------------------------------------------------- minesweeper
do
  local _, m = make("minesweeper", 2)
  m:reveal(4, 4)
  m:reveal(13, 12)
  -- flag a handful of known mines so the board looks played
  local flagged = 0
  for y = 1, m.rows do
    for x = 1, m.cols do
      local cell = m:at(x, y)
      if cell.mine and flagged < 6 then
        local touching = false
        for dy = -1, 1 do
          for dx = -1, 1 do
            local n = m:at(x + dx, y + dy)
            if n and n.shown then touching = true end
          end
        end
        if touching then
          m:toggleFlag(x, y)
          flagged = flagged + 1
        end
      end
    end
  end
  m.cursorX, m.cursorY = 9, 8
  m.time = 37
  shot("minesweeper", m)
end

----------------------------------------------------------------------- 2048
do
  local _, g = make("g2048")
  local dirs = { "left", "up", "left", "down" }
  run(g, 300, function(inst, f) inst:move(dirs[(f % 4) + 1]) end)
  shot("2048", g)
end

-------------------------------------------------------------------- sokoban
do
  data.progress("sokoban").level = 8
  local _, s = make("sokoban", 1)
  s:step(0, -1)
  s:step(-1, 0)
  shot("sokoban", s)
  data.progress("sokoban").level = 1
end

--------------------------------------------------------------------- flappy
do
  local _, f2 = make("flappy", 1)
  run(f2, 300, function(inst)
    if inst.state == "ready" then inst:flap() return end
    local best
    for _, p in ipairs(inst.pipes) do
      if p.x + 12 > 20 and (not best or p.x < best.x) then best = p end
    end
    local target = best and (best.gapY + inst.gap / 2) or 24
    if inst.y + 2 > target then inst:flap() end
  end)
  shot("flappy", f2)
end

----------------------------------------------------------------------- pong
do
  local _, p = make("pong", 2)
  run(p, 700, function(inst, f)
    local b = inst.ball
    if b then
      local centre = inst.leftY + 6 + (f % 60 < 30 and 3 or -3)
      hold(keys.w, b.y < centre - 1)
      hold(keys.s, b.y > centre + 1)
    end
  end)
  hold(keys.w, false)
  hold(keys.s, false)
  shot("pong", p)
end

-------------------------------------------------------------------- meteors
do
  local _, m = make("meteors")
  run(m, 120, function(inst, f)
    hold(keys.left, f % 40 < 20)
    hold(keys.right, f % 40 >= 20)
    if f % 7 == 0 then tap(inst, keys.space) end
  end)
  hold(keys.left, false)
  hold(keys.right, false)
  shot("meteors", m)
end

----------------------------------------------------------------- lightsout
do
  local _, l = make("lightsout", 2)
  -- press a few cells so the board looks played rather than freshly dealt
  for _, cell in ipairs({ { 2, 2 }, { 4, 3 }, { 3, 5 } }) do
    l.cursorX, l.cursorY = cell[1], cell[2]
    l:activate()
  end
  l.cursorX, l.cursorY = 3, 3
  run(l, 40, nil)
  shot("lightsout", l)
end

--------------------------------------------------------------------- simon
do
  local _, s = make("simon", 1)
  -- catch it mid-playback with a panel lit
  for _ = 1, 60 do
    s:update(0.05)
    if s.litPanel then break end
  end
  shot("simon", s)
end

------------------------------------------------------------------ connect4
do
  local _, c = make("connect4", 2)
  local COLS, ROWS = 7, 6
  local function drop(col, who)
    local row = ROWS - c.heights[col]
    c.board[(row - 1) * COLS + col] = who
    c.heights[col] = c.heights[col] + 1
    c.moves = c.moves + 1
  end
  drop(4, 1) drop(4, 2) drop(3, 1) drop(5, 2)
  drop(3, 2) drop(2, 1) drop(5, 1) drop(6, 2)
  drop(4, 1) drop(2, 2)
  c.cursor = 5
  c.turn = 1
  shot("connect4", c)
end

gfx.shutdown()
finish("shots")
