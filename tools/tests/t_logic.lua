-- Deterministic checks on game rules and library behaviour.
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

local function make(id, modeIdx)
  local def = req("games." .. id)
  return def, def.new(api, def.modes and def.modes[modeIdx or 1])
end

--------------------------------------------------------------- canvas maths
do
  local c = Canvas.new(1, 1, 4, 2, colors.black)
  c:clear(colors.black)
  -- left half of cell 1 white -> drawing char 149, fg white on black
  c:fill(1, 1, 1, 3, colors.white)
  local captured = {}
  local realBlit = term.blit
  term.blit = function(text, f, b) captured[#captured + 1] = { text, f, b } end
  c:render()
  term.blit = realBlit
  eq(string.byte(captured[1][1], 1), 128 + 21, "left-half cell char")
  eq(captured[1][2]:sub(1, 1), gfx.blit[colors.white], "left-half fg")
  eq(captured[1][3]:sub(1, 1), gfx.blit[colors.black], "left-half bg")

  c:clear(colors.black)
  c:set(1, 1, colors.red)
  captured = {}
  term.blit = function(text, f, b) captured[#captured + 1] = { text, f, b } end
  c:render()
  term.blit = realBlit
  eq(string.byte(captured[1][1], 1), 129, "single top-left pixel char")
  eq(captured[1][2]:sub(1, 1), gfx.blit[colors.red], "single pixel fg")

  c:clear(colors.blue)
  captured = {}
  term.blit = function(text, f, b) captured[#captured + 1] = { text, f, b } end
  c:render()
  term.blit = realBlit
  eq(captured[1][1]:sub(1, 1), " ", "uniform cell is a space")
  eq(captured[1][3]:sub(1, 1), gfx.blit[colors.blue], "uniform cell bg")

  -- three colours in one cell must still produce a legal blit
  c:clear(colors.black)
  c:set(1, 1, colors.red)
  c:set(2, 1, colors.lime)
  c:set(1, 2, colors.cyan)
  captured = {}
  term.blit = function(text, f, b) captured[#captured + 1] = { text, f, b } end
  c:render()
  term.blit = realBlit
  local code = string.byte(captured[1][1], 1)
  check(code == 32 or (code >= 128 and code <= 159), "3-colour cell emits a legal char")
  eq(#captured[1][1], 4, "row length matches canvas width")
end

-------------------------------------------------------------------- library
do
  eq(gfx.commas(1000), "1,000", "commas 1000")
  eq(gfx.commas(999), "999", "commas 999")
  eq(gfx.contrast(colors.white), colors.black, "white bg wants black text")
  eq(gfx.contrast(colors.black), colors.white, "black bg wants white text")
  eq(data.formatDuration(45), "45s", "duration seconds")
  eq(data.formatDuration(3600), "1h 00m", "duration hours")
  check(#audio.badNotes == 0, "every music note name resolves")
end

----------------------------------------------------------------- score table
do
  data.state.scores["_t"] = nil
  data.submit("_t", 100)
  data.submit("_t", 300)
  data.submit("_t", 200)
  local list = data.scores("_t")
  eq(list[1].score, 300, "highest score first")
  eq(list[3].score, 100, "lowest score last")
  eq(data.best("_t"), 300, "best is the top entry")
  for i = 1, 6 do data.submit("_t", i) end
  check(#data.scores("_t") <= 5, "table capped at five entries")

  data.state.scores["_lo"] = nil
  data.submit("_lo", 50, true)
  data.submit("_lo", 20, true)
  data.submit("_lo", 90, true)
  eq(data.scores("_lo")[1].score, 20, "lower-is-better sorts ascending")
  data.state.scores["_t"] = nil
  data.state.scores["_lo"] = nil
end

--------------------------------------------------------------------- tetris
do
  local def, t = make("tetris", 1)
  local shapesOK = true
  for _, kind in ipairs({ "I", "O", "T", "S", "Z", "J", "L" }) do
    for rot = 0, 3 do
      -- every rotation of every piece must be placeable mid-board
      if not t:fits(kind, rot, 4, 5) then shapesOK = false end
    end
  end
  check(shapesOK, "every rotation of every piece fits mid-board")

  -- rotating four times returns the piece to its start
  t = select(2, make("tetris", 1))
  t.kind = "T"
  t.px, t.py, t.rot = 4, 5, 0
  for _ = 1, 4 do t:rotate(1) end
  eq(t.rot, 0, "four clockwise rotations return to spawn")
  eq(t.px, 4, "no drift in x after a full turn")
  eq(t.py, 5, "no drift in y after a full turn")

  -- every rotation transition has a kick table, for both piece families
  local kickOK = true
  for _, kind in ipairs({ "I", "T" }) do
    for from = 0, 3 do
      t = select(2, make("tetris", 1))
      t.kind, t.px, t.py, t.rot = kind, 4, 6, from
      if not t:rotate(1) then kickOK = false end
      t.rot = from
      if not t:rotate(-1) then kickOK = false end
    end
  end
  check(kickOK, "all eight rotation transitions resolve for I and T")

  -- a completed row clears and scores
  t = select(2, make("tetris", 1))
  for x = 2, 10 do t.grid[20][x] = "O" end
  t.kind, t.rot, t.px, t.py = "I", 1, -1, 17
  local before = t.score
  t:lock()
  check(t.clearRows ~= nil, "single line registers a clear")
  eq(#t.clearRows, 1, "exactly one row cleared")
  eq(t.score - before, 100, "single clear scores 100 at level 1")
  t:collapse()
  eq(t.lines, 1, "line counter incremented")
  local emptied = true
  for x = 1, 10 do if t.grid[20][x] then emptied = false end end
  check(not emptied, "the leftover I cells fall to the bottom row")

  -- a tetris scores 800
  t = select(2, make("tetris", 1))
  for y = 17, 20 do
    for x = 2, 10 do t.grid[y][x] = "O" end
  end
  t.kind, t.rot, t.px, t.py = "I", 1, -1, 17
  before = t.score
  t:lock()
  eq(#t.clearRows, 4, "four rows cleared")
  eq(t.score - before, 800, "tetris scores 800 at level 1")

  -- hard drop lands the piece on the stack
  t = select(2, make("tetris", 1))
  t.kind, t.rot, t.px, t.py = "O", 0, 5, 1
  t:hardDrop()
  check(t.grid[20][5] ~= false and t.grid[20][6] ~= false, "hard drop reaches the floor")

  -- hold swaps and locks out until the next piece
  t = select(2, make("tetris", 1))
  local first = t.kind
  t:swapHold()
  eq(t.hold, first, "held piece recorded")
  check(t.holdUsed, "hold is spent")
  local afterHold = t.kind
  t:swapHold()
  eq(t.kind, afterHold, "second hold in the same turn is refused")
end

----------------------------------------------------------------------- 2048
do
  local def, g = make("g2048")
  local function setGrid(vals)
    for i = 1, 16 do g.grid[i] = vals[i] or 0 end
  end
  -- the slide animation defers the spawn, so settle between moves
  local function slide(dir)
    g:move(dir)
    g:update(0.3)
  end

  setGrid({ 2, 2, 4, 4 })
  g.score = 0
  slide("left")
  -- a spawn lands somewhere, so only check the merged pair
  eq(g:get(1, 1), 4, "2+2 merges to 4")
  eq(g:get(2, 1), 8, "4+4 merges to 8")
  eq(g.score, 12, "merge score is 4 + 8")

  setGrid({ 2, 2, 2, 0 })
  g.score = 0
  slide("left")
  eq(g:get(1, 1), 4, "only the leading pair merges")
  eq(g:get(2, 1), 2, "third tile slides but does not merge")

  setGrid({ 0, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0 })
  g.score = 0
  slide("up")
  eq(g:get(1, 1), 4, "vertical merge works")

  -- a full board with no equal neighbours is game over
  setGrid({ 2, 4, 2, 4, 4, 2, 4, 2, 2, 4, 2, 4, 4, 2, 4, 2 })
  check(not g:hasMove(), "checkerboard board has no moves")
  setGrid({ 2, 2, 2, 4, 4, 2, 4, 2, 2, 4, 2, 4, 4, 2, 4, 2 })
  check(g:hasMove(), "equal neighbours mean a move exists")

  -- undo restores the previous board
  setGrid({ 2, 2, 0, 0 })
  g.finished = false
  g.score = 0
  slide("left")
  local movedScore = g.score
  g:undo()
  eq(g:get(1, 1), 2, "undo restores tile 1")
  eq(g:get(2, 1), 2, "undo restores tile 2")
  eq(g.score, 0, "undo restores the score")
  check(movedScore > 0, "the move had scored before undo")
end

---------------------------------------------------------------------- snake
do
  local def, s = make("snake", 1)
  local startLen = s:length()
  -- drop food directly in front of the head
  local head = s.body[s.head]
  s.food = { x = head.x + 1, y = head.y }
  s:step()
  eq(s.apples, 1, "apple eaten")
  check(s.score > 0, "eating scores")
  s:step()
  s:step()
  check(s:length() > startLen, "snake grew after eating")

  -- walls kill in classic mode
  local _, s2 = make("snake", 1)
  local h = s2.body[s2.head]
  s2.body[s2.head] = { x = 32, y = h.y }
  s2.occ = {}
  s2.occ[(h.y - 1) * 32 + 32] = true
  s2:step()
  check(s2.dying > 0, "hitting the wall starts the death animation")

  -- wrap mode survives the same move
  local _, s3 = make("snake", 2)
  local h3 = s3.body[s3.head]
  s3.body[s3.head] = { x = 32, y = h3.y }
  s3:step()
  eq(s3.dying, 0, "wrap mode passes through the wall")
  eq(s3.body[s3.head].x, 1, "wrap mode reappears on the left")
end

--------------------------------------------------------------- minesweeper
do
  local def, m = make("minesweeper", 1)
  m:reveal(5, 5)
  check(m.started, "first click lays the mines")
  local safe = true
  for dy = -1, 1 do
    for dx = -1, 1 do
      local cell = m:at(5 + dx, 5 + dy)
      if cell and cell.mine then safe = false end
    end
  end
  check(safe, "first click and its neighbours are mine-free")
  check(m.revealed > 0, "first click reveals something")

  -- flag toggling tracks the counter
  local before = m.flags
  m:toggleFlag(1, 1)
  eq(m.flags, before + 1, "flag raises the counter")
  m:toggleFlag(1, 1)
  eq(m.flags, before, "unflag lowers the counter")

  -- revealing every safe square wins
  local _, w = make("minesweeper", 1)
  w:reveal(5, 5)
  for y = 1, w.rows do
    for x = 1, w.cols do
      local cell = w:at(x, y)
      if not cell.mine and not cell.shown then w:reveal(x, y) end
    end
  end
  check(w.won, "clearing every safe square wins")
  check(w.finished, "winning finishes the game")
  check(w.score > 0, "a win scores")

  -- stepping on a mine loses
  local _, l = make("minesweeper", 1)
  l:reveal(5, 5)
  local mx, my
  for y = 1, l.rows do
    for x = 1, l.cols do
      if l:at(x, y).mine then mx, my = x, y break end
    end
    if mx then break end
  end
  check(mx ~= nil, "the board has mines")
  l:reveal(mx, my)
  check(l.finished and not l.won, "stepping on a mine ends the game")
end

-------------------------------------------------------------------- sokoban
do
  data.progress("sokoban").level = 1
  local def, s = make("sokoban", 1)
  eq(s.index, 1, "starts on level 1")
  eq(s.def.par, 2, "level 1 par is the solved optimum")
  -- level 1: crates at (3,3),(4,3), goals below them, player at (5,4).
  -- Walk over each crate in turn and push it down.
  local solution = {
    { 0, -1 }, { 0, -1 }, { -1, 0 }, { 0, 1 },
    { 0, -1 }, { -1, 0 }, { 0, 1 },
  }
  for _, mv in ipairs(solution) do s:step(mv[1], mv[2]) end
  check(s.won, "scripted solution solves level 1")
  eq(s.pushes, 2, "solved with the optimal number of pushes")
  check(s.score > 0, "solving scores")
  eq(data.progress("sokoban").level, 2, "progress advances to level 2")

  -- configure() passes the mode through untouched unless a level was picked
  local sokDef = req("games.sokoban")
  check(type(sokDef.configure) == "function", "sokoban exposes configure")
  local plain = { id = "continue" }
  eq(sokDef.configure(api, plain), plain, "configure is a no-op without select")

  -- undo rewinds a push
  data.progress("sokoban").level = 1
  local _, u = make("sokoban", 1)
  local boxesBefore = 0
  for _ in pairs(u.boxes) do boxesBefore = boxesBefore + 1 end
  u:step(0, -1)
  u:step(-1, 0)
  local movesAfter = u.moves
  u:undo()
  eq(u.moves, movesAfter - 1, "undo rewinds one move")
  local boxesAfter = 0
  for _ in pairs(u.boxes) do boxesAfter = boxesAfter + 1 end
  eq(boxesAfter, boxesBefore, "undo keeps the crate count")
  data.progress("sokoban").level = 1
end

------------------------------------------------------------------- breakout
do
  local def, b = make("breakout", 1)
  local before = b.remaining
  local scoreBefore = b.score
  -- find a one-hit brick and shoot it
  local hitRow, hitCol
  for r = 1, 8 do
    for col = 1, 12 do
      local brick = b.bricks[r][col]
      if brick and brick.hp == 1 then hitRow, hitCol = r, col break end
    end
    if hitRow then break end
  end
  check(hitRow ~= nil, "level 1 has a breakable brick")
  b:hitBrick(hitRow, hitCol)
  eq(b.remaining, before - 1, "breaking a brick lowers the count")
  check(b.score > scoreBefore, "breaking a brick scores")
  eq(b.bricks[hitRow][hitCol], false, "the brick is gone")

  -- a two-hit brick survives the first strike
  local _, b2 = make("breakout", 2)
  local tr, tc
  for r = 1, 8 do
    for col = 1, 12 do
      local brick = b2.bricks[r][col]
      if brick and brick.hp == 2 then tr, tc = r, col break end
    end
    if tr then break end
  end
  if tr then
    b2:hitBrick(tr, tc)
    check(b2.bricks[tr][tc] ~= false, "tough brick survives one hit")
    b2:hitBrick(tr, tc)
    eq(b2.bricks[tr][tc], false, "tough brick dies on the second hit")
  end
end

----------------------------------------------------------------------- pong
do
  local def, p = make("pong", 2)
  for _ = 1, 11 do p:point("left") end
  eq(p.leftScore, 11, "left reaches the target")
  check(p.finished, "reaching eleven ends the match")
  check(p.won, "the player won")
  check(p.score > 0, "a win scores")
end

-------------------------------------------------------------------- meteors
do
  local def, m = make("meteors")
  local rocksBefore = #m.rocks
  local scoreBefore = m.score
  m:splitRock(1)
  eq(#m.rocks, rocksBefore + 1, "a large rock splits into two")
  check(m.score > scoreBefore, "shooting a rock scores")
  -- smallest rocks vanish
  local small = nil
  for i, r in ipairs(m.rocks) do if r.size == 1 then small = i end end
  if not small then
    m.rocks[#m.rocks + 1] = { x = 10, y = 10, size = 1, r = 4, shape = { 1, 1, 1 },
      angle = 0, spin = 0, vx = 0, vy = 0 }
    small = #m.rocks
  end
  local n = #m.rocks
  m:splitRock(small)
  eq(#m.rocks, n - 1, "the smallest rocks do not split")
end

------------------------------------------------------------------- flappy
do
  local def, f = make("flappy", 1)
  eq(f.state, "ready", "starts in the ready state")
  f:flap()
  eq(f.state, "play", "first flap starts the run")
  check(f.vy < 0, "flapping pushes the bird upward")
  f.y = 60
  f:die()
  eq(f.state, "dead", "hitting something kills the bird")
  for _ = 1, 40 do f:update(0.05) end
  check(f.finished, "the death animation ends the run")
end

gfx.shutdown()
finish("logic")
