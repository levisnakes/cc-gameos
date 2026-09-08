-- Long sessions driven by simple bots, so level transitions, wave changes and
-- late-game states actually get reached. Plus environment edge cases.
local req = require_gameos
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local font = req("lib.font")
local input = req("lib.input")
local audio = req("lib.audio")
local data = req("lib.data")

check(gfx.init(), "gfx.init")
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

--- Run a bot for up to `frames` frames. bot(inst, frame) runs before update.
local function play(label, inst, frames, bot)
  local ran = 0
  for f = 1, frames do
    ran = f
    if bot then
      local ok, err = pcall(bot, inst, f)
      if not ok then
        check(false, label .. " bot failed at frame " .. f .. ": " .. tostring(err))
        break
      end
    end
    local ok, err = pcall(inst.update, inst, 0.05)
    if not ok then
      check(false, label .. " update failed at frame " .. f .. ": " .. tostring(err))
      break
    end
    gfx.beginFrame()
    local dok, derr = pcall(inst.draw, inst)
    gfx.endFrame()
    if not dok then
      check(false, label .. " draw failed at frame " .. f .. ": " .. tostring(derr))
      break
    end
    input.endFrame()
    if inst.finished then break end
  end
  return ran
end

local function hold(code, down)
  if down then input.onKey(code, false) else input.onKeyUp(code) end
end

local function tap(inst, code)
  input.onKey(code, false)
  if inst.onKey then inst:onKey(code, false) end
  input.onKeyUp(code)
end

------------------------------------------------------------------- tetris
do
  -- A real placement search, so the bot clears lines and reaches later
  -- levels instead of choking the well with holes.
  local function scorePlacement(inst, kind, rot, px)
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

    local cleared = 0
    for y = 1, 20 do
      local full = true
      for x = 1, 10 do if not g[y][x] then full = false break end end
      if full then cleared = cleared + 1 end
    end

    local aggregate, holes, prev, bumpiness = 0, 0, nil, 0
    for x = 1, 10 do
      local top = nil
      for y = 1, 20 do
        if g[y][x] then top = y break end
      end
      local height = top and (21 - top) or 0
      aggregate = aggregate + height
      if top then
        for y = top + 1, 20 do
          if not g[y][x] then holes = holes + 1 end
        end
      end
      if prev then bumpiness = bumpiness + math.abs(height - prev) end
      prev = height
    end

    return 0.76 * cleared - 0.51 * aggregate - 0.36 * holes - 0.18 * bumpiness
  end

  local def, t = make("tetris", 1)
  local frames = play("tetris", t, 6000, function(inst, f)
    if f % 6 ~= 0 or inst.clearRows or inst.finished then return end
    local bestScore, bestRot, bestX
    for rot = 0, 3 do
      for px = -2, 10 do
        local s = scorePlacement(inst, inst.kind, rot, px)
        if s and (not bestScore or s > bestScore) then
          bestScore, bestRot, bestX = s, rot, px
        end
      end
    end
    if not bestScore then return end
    while inst.rot ~= bestRot do
      if not inst:rotate(1) then break end
    end
    local guard = 0
    while inst.px ~= bestX and guard < 14 do
      guard = guard + 1
      if not inst:tryMove(inst.px < bestX and 1 or -1, 0) then break end
    end
    tap(inst, keys.space)
  end)
  LOG(string.format("  tetris: %d frames, %d lines, level %d, score %d",
    frames, t.lines, t.level, t.score))
  check(t.lines > 0, "the tetris bot cleared lines")
  check(t.score > 0, "the tetris bot scored")
  check(t.pieces > 20, "many pieces were played")
end

----------------------------------------------------------------- breakout
do
  local def, b = make("breakout", 1)
  local frames = play("breakout", b, 6000, function(inst, f)
    local ball = inst.balls[1]
    if ball then
      -- track slightly off-centre, the way a person would
      inst.mouseTarget = ball.x - inst.paddleW / 2 + 1 + (f % 40 < 20 and 2 or -2)
    end
    if f % 5 == 0 then tap(inst, keys.space) end
  end)
  LOG(string.format("  breakout: %d frames, level %d, %d bricks, score %d, lives %d",
    frames, b.levelIndex, b.bricksBroken, b.score, b.lives))
  check(b.bricksBroken > 20, "the breakout bot broke bricks")
  check(b.levelIndex > 1 or b.finished, "the bot advanced a level or lost fairly")
end

----------------------------------------------------------------- invaders
do
  local def, v = make("invaders", 1)
  local frames = play("invaders", v, 6000, function(inst, f)
    -- chase the lowest surviving alien, firing constantly
    local target = nil
    for i = 1, #inst.aliens do
      local a = inst.aliens[i]
      if a.alive and (not target or a.y > target.y) then target = a end
    end
    if target then
      hold(keys.left, target.x + 4 < inst.playerX + 4)
      hold(keys.right, target.x + 4 > inst.playerX + 4)
    end
    if f % 6 == 0 then tap(inst, keys.space) end
  end)
  LOG(string.format("  invaders: %d frames, wave %d, %d kills, score %d",
    frames, v.wave, v.kills, v.score))
  check(v.kills > 20, "the invaders bot shot aliens")
  hold(keys.left, false)
  hold(keys.right, false)
end

-------------------------------------------------------------------- snake
do
  local def, s = make("snake", 2)
  local frames = play("snake", s, 4000, function(inst)
    -- steer toward the apple on whichever axis is furthest out
    local head = inst.body[inst.head]
    local food = inst.food
    if not (head and food) then return end
    local dx = food.x - head.x
    local dy = food.y - head.y
    if math.abs(dx) >= math.abs(dy) and dx ~= 0 then
      inst:turn(dx > 0 and "right" or "left")
    elseif dy ~= 0 then
      inst:turn(dy > 0 and "down" or "up")
    end
  end)
  LOG(string.format("  snake: %d frames, length %d, %d apples, score %d",
    frames, s:length(), s.apples, s.score))
  check(s.apples > 5, "the snake bot ate apples")
  check(s.score > 0, "the snake bot scored")
end

---------------------------------------------------------------------- 2048
do
  local def, g = make("g2048")
  local dirs = { "left", "up", "right", "down" }
  local frames = play("2048", g, 4000, function(inst, f)
    inst:move(dirs[(f % 4) + 1])
  end)
  LOG(string.format("  2048: %d frames, %d moves, biggest %d, score %d",
    frames, g.moves, g.biggest, g.score))
  check(g.biggest >= 32, "the 2048 bot built a decent tile")
  check(g.finished, "the 2048 bot filled the board")
end

-------------------------------------------------------------------- flappy
do
  local def, f2 = make("flappy", 1)
  local frames = play("flappy", f2, 4000, function(inst)
    if inst.state == "ready" then
      inst:flap()
      return
    end
    -- aim for the middle of the nearest gap ahead
    local best = nil
    for _, p in ipairs(inst.pipes) do
      if p.x + 12 > 20 and (not best or p.x < best.x) then best = p end
    end
    local target = best and (best.gapY + inst.gap / 2) or 24
    if inst.y + 2 > target then inst:flap() end
  end)
  LOG(string.format("  flappy: %d frames, %d pipes", frames, f2.score))
  check(f2.score > 3, "the flappy bot cleared pipes")
end

---------------------------------------------------------------------- pong
-- Every CPU difficulty must produce a match that actually ends.
for mode = 1, 3 do
  local def, p = make("pong", mode)
  local frames = play("pong", p, 14000, function(inst, f)
    local b = inst.ball
    if b then
      local centre = inst.leftY + 6 + (f % 60 < 30 and 2 or -2)
      hold(keys.w, b.y < centre - 1)
      hold(keys.s, b.y > centre + 1)
    end
  end)
  LOG(string.format("  pong %s: %d frames, %d-%d, longest rally %d",
    def.modes[mode].name, frames, p.leftScore, p.rightScore, p.longestRally))
  check(p.finished, "pong mode " .. mode .. " reached eleven")
  check(p.longestRally > 2, "pong mode " .. mode .. " had rallies")
  hold(keys.w, false)
  hold(keys.s, false)
end

------------------------------------------------------------------- meteors
do
  local def, m = make("meteors")
  local frames = play("meteors", m, 6000, function(inst, f)
    -- spin and fire; hyperspace out of trouble
    hold(keys.left, f % 40 < 20)
    hold(keys.right, f % 40 >= 20)
    if f % 5 == 0 then tap(inst, keys.space) end
    if f % 400 == 0 then tap(inst, keys.h) end
  end)
  LOG(string.format("  meteors: %d frames, wave %d, %d rocks, score %d",
    frames, m.wave, m.rocksShot, m.score))
  check(m.rocksShot > 10, "the meteors bot shot rocks")
  hold(keys.left, false)
  hold(keys.right, false)
end

--------------------------------------------------------- save file handling
do
  data.state.settings.theme = "amber"
  data.submit("deeptest", 1234)
  check(data.save(), "save writes")
  local raw = fs.open("/gameos/data/save.dat", "r").readAll()
  check(#raw > 0, "save file has content")
  data.state = nil
  data.load()
  eq(data.get("theme"), "amber", "settings survive a round trip")
  eq(data.best("deeptest"), 1234, "scores survive a round trip")

  -- a corrupt save must not stop the console booting
  local handle = fs.open("/gameos/data/save.dat", "w")
  handle.write("this is not lua {{{")
  handle.close()
  local ok = pcall(data.load)
  check(ok, "corrupt save file loads without erroring")
  eq(data.get("theme"), "midnight", "corrupt save falls back to defaults")

  -- an unexpected value type is ignored rather than adopted
  handle = fs.open("/gameos/data/save.dat", "w")
  handle.write('{ settings = { volMaster = "loud", volMusic = 3 } }')
  handle.close()
  data.load()
  eq(data.get("volMaster"), 7, "wrongly typed setting falls back to the default")
  eq(data.get("volMusic"), 3, "correctly typed setting is kept")
  fs.delete("/gameos/data/save.dat")
  data.load()
end

------------------------------------------------------------ no speaker path
do
  MOCK.speakerPresent = false
  audio.speaker = nil
  audio.init()
  check(audio.speaker == nil, "no speaker detected")
  audio.play("explode")
  audio.playMusic("menu")
  audio.update(1)
  audio.update(2)
  local def, s = make("snake", 1)
  play("snake-silent", s, 120, nil)
  check(true, "games run with no speaker attached")
  MOCK.speakerPresent = true
  audio.init()
end

gfx.shutdown()
finish("deep")
