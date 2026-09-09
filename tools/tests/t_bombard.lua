-- Bombard: the rules, the determinism the network play rests on, and the
-- opponent's difficulty ladder.
--
-- The determinism checks matter more here than anywhere else in the console.
-- Two players on two computers only stay in the same match because both
-- simulate identically from a shared seed, so anything that makes the same
-- inputs produce a different answer is a bug that would show up as one
-- player's shell landing somewhere the other never saw.

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

local def = req("games.bombard")

local function make(modeId, extra)
  local mode
  for _, m in ipairs(def.modes) do if m.id == modeId then mode = m end end
  check(mode ~= nil, "mode " .. tostring(modeId) .. " exists")
  local copy = {}
  for k, v in pairs(mode) do copy[k] = v end
  for k, v in pairs(extra or {}) do copy[k] = v end
  return def.new(api, copy)
end

local function run(inst, frames, bot)
  for f = 1, frames do
    if bot then bot(inst, f) end
    inst:update(0.05)
    gfx.beginFrame()
    inst:draw()
    gfx.endFrame()
    input.endFrame()
    if inst.finished then return f end
  end
  return frames
end

---------------------------------------------------------------- determinism
-- The same seed has to build the same world, every time, on every console.
do
  local a = make("hotseat", { seed = 424242 })
  local b = make("hotseat", { seed = 424242 })
  check(a:fingerprint() == b:fingerprint(), "the same seed builds the same world")
  check(a.tanks[1].x == b.tanks[1].x and a.tanks[2].x == b.tanks[2].x,
    "the same seed places the tanks identically")
  check(a.wind == b.wind, "the same seed gives the same opening wind")

  local c = make("hotseat", { seed = 999 })
  check(c:fingerprint() ~= a:fingerprint(), "a different seed builds a different world")

  -- and the wind stream has to stay in step across many turns, since it is
  -- advanced independently on each console
  for _ = 1, 40 do a:newWind() b:newWind() end
  check(a.wind == b.wind, "the wind streams stay in step over a long match")

  -- the same shot must produce the same flight
  local pa, ia = a:simulate(10, 30, 45, 60, 4)
  local pb, ib = b:simulate(10, 30, 45, 60, 4)
  check(#pa == #pb, "the same shot flies for the same number of steps")
  check(ia.x == ib.x and ia.y == ib.y, "the same shot lands in the same place")
end

-- Terrain generation must not touch math.random, or another game drawing
-- randoms first would shift the world out from under a networked match.
do
  math.randomseed(1)
  local a = make("hotseat", { seed = 31337 })
  for _ = 1, 50 do math.random() end
  math.randomseed(99)
  local b = make("hotseat", { seed = 31337 })
  check(a:fingerprint() == b:fingerprint(),
    "terrain ignores math.random, so other games cannot disturb a match")
end

------------------------------------------------------------------ ballistics
do
  local g = make("hotseat", { seed = 5150 })

  -- wind has to actually push the shell
  local _, left = g:simulate(50, 20, 90, 60, -10)
  local _, right = g:simulate(50, 20, 90, 60, 10)
  check(right.x > left.x, "wind carries the shell downrange")

  -- more power has to reach further
  local _, weak = g:simulate(10, 20, 45, 20, 0)
  local _, strong = g:simulate(10, 20, 45, 90, 0)
  check(strong.x > weak.x, "more power carries further")

  -- every shot has to end somewhere; a shot that never resolves would hang
  -- the flight phase forever
  for angle = 0, 180, 15 do
    for power = 5, 100, 19 do
      local path, imp = g:simulate(50, 20, angle, power, 0)
      check(#path > 1, "shot " .. angle .. "/" .. power .. " produced a path")
      check(imp.ground or imp.off or imp.hit,
        "shot " .. angle .. "/" .. power .. " resolved")
    end
  end
end

--------------------------------------------------------------------- damage
do
  local g = make("hotseat", { seed = 777 })
  local t = g.tanks[1]
  local before = t.health
  local solidBefore = 0
  for _ = 1, 1 do
    for i = 1, #g.runs do solidBefore = solidBefore + g.runs[i][3] end
  end

  g:applyBlast(t.x, t.y)                    -- right on top of it
  check(t.health < before, "a blast on a tank hurts it")
  check(t.health <= before - 30, "a direct hit hurts a lot (took " ..
    (before - t.health) .. ")")

  local solidAfter = 0
  for i = 1, #g.runs do solidAfter = solidAfter + g.runs[i][3] end
  check(solidAfter < solidBefore, "a blast digs a crater (" ..
    solidBefore .. " -> " .. solidAfter .. " pixels of ground)")

  -- a distant blast should not reach
  local far = g.tanks[2]
  local farBefore = far.health
  g:applyBlast(far.x, far.y - 40)
  check(far.health == farBefore, "a blast well overhead does not hurt")
end

------------------------------------------------------------------- a match
-- Play the computer at each level and confirm matches actually end, that the
-- opponent can shoot, and that harder settings really do shoot better.
local function accuracy(modeId, seed)
  local g = make(modeId, { seed = seed })
  -- The human never fires, so this measures the opponent alone: every shot
  -- on the board is theirs.
  local frames = run(g, 4000, function(inst)
    if inst.phase == "aim" and inst.turn == 1 then
      inst:fire(45, 55)                     -- a fixed, mediocre lob
    end
  end)
  return g, frames
end

do
  local results = {}
  for _, id in ipairs({ "easy", "normal", "hard" }) do
    local hits, shots, wins = 0, 0, 0
    for seed = 1, 6 do
      local g = accuracy(id, seed * 1013)
      hits = hits + g.hits[2]
      shots = shots + g.shots[2]
      if g.winner == 2 then wins = wins + 1 end
    end
    results[id] = { hits = hits, shots = shots, wins = wins }
    LOG(string.format("  bombard %-6s  %d/%d shots on target, won %d of 6",
      id, hits, shots, wins))
    check(shots > 0, id .. " opponent took shots")
  end

  check(results.hard.hits / math.max(1, results.hard.shots) >
        results.easy.hits / math.max(1, results.easy.shots),
    "the hard opponent shoots straighter than the easy one")
  check(results.hard.wins >= results.easy.wins,
    "the hard opponent wins at least as often")
end

------------------------------------------------------- is it actually fair?
-- The check that matters, and the one Invaders needed and never had: can a
-- competent player win? An opponent that always wins is not difficulty, it is
-- a broken game, and it looks perfectly healthy in every other test here.
--
-- The reference player is modelled the same way the opponent is -- search for
-- a shot, then miss by a human-sized margin -- so the comparison is fair
-- rather than a bot with a hand-tuned advantage.
do
  local REF_TRIES, REF_ERROR = 30, 10

  local function playAgainst(modeId, games)
    local wins = 0
    for seed = 1, games do
      local g = make(modeId, { seed = seed * 7919 })
      for _ = 1, 9000 do
        if g.phase == "aim" and g.turn == 1 then
          local savedT, savedE = g.cpuTries, g.cpuError
          g.cpuTries, g.cpuError = REF_TRIES, REF_ERROR
          local a, p = g:planCpuShot(1)
          g.cpuTries, g.cpuError = savedT, savedE
          g:fire(a, p)
        end
        g:update(0.05)
        if g.finished then break end
      end
      if g.winner == 1 then wins = wins + 1 end
    end
    return wins
  end

  local GAMES = 24
  local easy = playAgainst("easy", GAMES)
  local normal = playAgainst("normal", GAMES)
  local hard = playAgainst("hard", GAMES)
  LOG(string.format("  a competent player wins  easy %d/%d  normal %d/%d  hard %d/%d",
    easy, GAMES, normal, GAMES, hard, GAMES))

  check(easy >= GAMES * 0.65, "easy really is easy (" .. easy .. "/" .. GAMES .. ")")
  check(normal >= GAMES * 0.35 and normal <= GAMES * 0.85,
    "normal is a real contest (" .. normal .. "/" .. GAMES .. ")")
  check(hard >= GAMES * 0.12, "hard is beatable (" .. hard .. "/" .. GAMES .. ")")
  check(hard <= easy, "and still harder than easy")
end

-- a match between two fixed shooters must terminate rather than stalemate
do
  local g = make("hotseat", { seed = 20250908 })
  local frames = run(g, 6000, function(inst)
    if inst.phase == "aim" then
      local t = inst:current()
      inst:fire(t.angle + (math.random() * 20 - 10), 55 + math.random() * 20)
    end
  end)
  check(g.finished, "a hot-seat match reaches an end (" .. frames .. " frames)")
  check(g.winner ~= nil, "someone won")
end

------------------------------------------------------- the game over card
-- The runtime shows at most four summary rows and expects pairs of strings;
-- anything else would come out blank or throw on the card.
do
  local g = make("normal", { seed = 12345 })
  run(g, 3000, function(inst)
    if inst.phase == "aim" and inst.turn == 1 then inst:fire(48, 62) end
  end)
  check(g.finished, "played a match through to the card")

  local ok, rows = pcall(g.summary, g)
  check(ok, "summary() runs: " .. tostring(rows))
  check(type(rows) == "table" and #rows > 0, "summary() returns rows")
  check(#rows <= 4, "and no more than the card can show (" .. #rows .. ")")
  for i = 1, #rows do
    check(type(rows[i][1]) == "string" and type(rows[i][2]) == "string",
      "summary row " .. i .. " is a pair of strings")
  end

  -- a match that ended because the opponent vanished must say so, and must
  -- not be scored as a win
  local d = make("normal", { seed = 55 })
  d.link = { close = function() end }
  d.me = 1
  d.byDisconnect = true
  d:finish(1)
  check(d.score == 0, "a disconnect is not scored as a win")
  local drows = d:summary()
  check(drows[#drows][2] == "opponent lost", "and the card says what happened")
end

----------------------------------------------------------------- screenshots
do
  local g = make("normal", { seed = 8899 })
  gfx.beginFrame() g:draw() gfx.endFrame()
  SHOT("bombard-aim")

  -- fire a good arc and catch it in the air
  g:fire(52, 70)
  run(g, 6)
  gfx.beginFrame() g:draw() gfx.endFrame()
  SHOT("bombard-flight")

  -- land several shots so the terrain is visibly chewed up
  run(g, 2000, function(inst)
    if inst.phase == "aim" and inst.turn == 1 then
      inst:fire(40 + math.random() * 30, 55 + math.random() * 25)
    end
  end)
  gfx.beginFrame() g:draw() gfx.endFrame()
  SHOT("bombard-cratered")
end

gfx.shutdown()
finish("bombard")
