-- Checks that the Connect Four opponent actually plays, rather than just
-- running without crashing: it must take wins, block threats, and beat a
-- random player almost every time.
local req = require_gameos
local gfx = req("lib.gfx")
local input = req("lib.input")
local audio = req("lib.audio")
local data = req("lib.data")

gfx.init()
data.load()
audio.init()

local api = {
  version = "test", gfx = gfx, canvas = req("lib.canvas"), font = req("lib.font"),
  input = input, audio = audio, data = data, ui = req("lib.ui"), require = req,
}

local def = req("games.connect4")
local COLS, ROWS = 7, 6
local HUMAN, CPU = 1, 2

local function fresh(modeIdx)
  return def.new(api, def.modes[modeIdx])
end

local function idx(col, row) return (row - 1) * COLS + col end

--- Drop discs into columns from a compact description, alternating nothing:
--- each entry is {column, player}.
local function setup(game, drops)
  for _, drop in ipairs(drops) do
    local col, player = drop[1], drop[2]
    local row = ROWS - game.heights[col]
    game.board[idx(col, row)] = player
    game.heights[col] = game.heights[col] + 1
    game.moves = game.moves + 1
  end
end

---------------------------------------------------------- takes a free win
do
  local g = fresh(2)
  -- CPU has three along the bottom of columns 2, 3, 4; column 5 completes it
  setup(g, { { 2, CPU }, { 3, CPU }, { 4, CPU }, { 2, HUMAN }, { 3, HUMAN } })
  g.turn = CPU
  local pick = g:chooseColumn()
  check(pick == 1 or pick == 5, "CPU completes its own four (picked " .. tostring(pick) .. ")")
end

--------------------------------------------------------- blocks a threat
do
  local g = fresh(2)
  -- the player threatens along the bottom of 2, 3, 4
  setup(g, { { 2, HUMAN }, { 3, HUMAN }, { 4, HUMAN }, { 2, CPU }, { 3, CPU } })
  g.turn = CPU
  local pick = g:chooseColumn()
  check(pick == 1 or pick == 5, "CPU blocks the open three (picked " .. tostring(pick) .. ")")
end

------------------------------------------------- vertical threat is blocked
do
  local g = fresh(2)
  setup(g, { { 4, HUMAN }, { 4, HUMAN }, { 4, HUMAN } })
  g.turn = CPU
  local pick = g:chooseColumn()
  eq(pick, 4, "CPU caps a vertical three")
end

------------------------------------------------------ beats a random player
do
  local wins, draws, losses = 0, 0, 0
  local GAMES = 12
  for _ = 1, GAMES do
    local g = fresh(3)  -- Hard
    local guard = 0
    while not g.finished and guard < 60 do
      guard = guard + 1
      if g.turn == HUMAN then
        -- random legal move
        local options = {}
        for c = 1, COLS do
          if g.heights[c] < ROWS then options[#options + 1] = c end
        end
        if #options == 0 then break end
        g:place(options[math.random(1, #options)], HUMAN)
      else
        local col = g:chooseColumn()
        if not col then break end
        g:place(col, CPU)
      end
    end
    if g.finished and g.message == "CPU WINS" then
      wins = wins + 1
    elseif g.finished and g.message == "A DRAW" then
      draws = draws + 1
    else
      losses = losses + 1
    end
  end
  LOG(string.format("  hard CPU vs random: %d won, %d drawn, %d lost of %d",
    wins, draws, losses, GAMES))
  check(wins >= GAMES - 1, "hard CPU beats a random player nearly every game")
end

--------------------------------------------- difficulty ordering is real
-- A strong searcher plays the human side by mirroring the board, so both
-- sides run the same code and only depth differs.
local function bestForHuman(game, depth)
  local mirror = fresh(2)
  mirror.depth = depth
  mirror.slack = 0
  for i = 1, COLS * ROWS do
    local v = game.board[i]
    if v == 0 then
      mirror.board[i] = 0
    else
      mirror.board[i] = (v == HUMAN) and CPU or HUMAN
    end
  end
  for c = 1, COLS do mirror.heights[c] = game.heights[c] end
  return mirror:chooseColumn()
end

--- Play one game. `firstMove` forces the opening column so a deterministic
--- pair of engines produces a different game each time.
local function match(cpuDepth, cpuSlack, humanDepth, firstMove)
  local g = fresh(2)
  g.depth = cpuDepth
  g.slack = cpuSlack
  g:place(firstMove, HUMAN)
  local guard = 0
  while not g.finished and guard < 60 do
    guard = guard + 1
    if g.turn == HUMAN then
      local col = bestForHuman(g, humanDepth)
      if not col then break end
      g:place(col, HUMAN)
    else
      local col = g:chooseColumn()
      if not col then break end
      g:place(col, CPU)
    end
  end
  return g.message
end

--- Score a whole engine over every opening: 2 for a win, 1 for a draw.
local function rate(cpuDepth, cpuSlack, humanDepth)
  local points, wins, draws = 0, 0, 0
  for opening = 1, COLS do
    local result = match(cpuDepth, cpuSlack, humanDepth, opening)
    if result == "CPU WINS" then
      points = points + 2
      wins = wins + 1
    elseif result == "A DRAW" then
      points = points + 1
      draws = draws + 1
    end
  end
  return points, wins, draws
end

do
  -- Faced with the same competent opponent, deeper must do better. A weak
  -- reference opponent blunders unpredictably and tells you nothing, so the
  -- yardstick here is a depth-4 player.
  local easyPts, easyWins = rate(2, 0, 4)
  local normalPts, normalWins = rate(4, 0, 4)
  local hardPts, hardWins = rate(5, 0, 4)
  LOG(string.format("  vs a depth-4 player over 7 openings: easy %d pts (%d wins), " ..
    "normal %d pts (%d wins), hard %d pts (%d wins)",
    easyPts, easyWins, normalPts, normalWins, hardPts, hardWins))
  check(hardPts > easyPts, "hard outperforms easy against the same opponent")
  check(hardPts >= normalPts, "hard is at least as good as normal")
  check(hardWins >= 4, "hard wins the majority of openings")
end

-------------------------------------------------------------- search budget
do
  local g = fresh(3)
  g:chooseColumn()
  LOG(string.format("  hard search on an empty board: %d nodes", g.lastNodes or -1))
  check((g.lastNodes or 0) < 20000, "search stays well inside its node ceiling")

  -- a midgame position is the realistic worst case
  setup(g, { { 4, HUMAN }, { 4, CPU }, { 3, HUMAN }, { 5, CPU }, { 3, CPU }, { 2, HUMAN } })
  g:chooseColumn()
  LOG(string.format("  hard search mid-game: %d nodes", g.lastNodes or -1))
end

gfx.shutdown()
finish("ai")
