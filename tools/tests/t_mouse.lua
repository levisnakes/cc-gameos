-- Mouse control, checked for effect rather than for absence of a crash.
--
-- Every game that claims a pointer control gets driven here and has to prove
-- the pointer did something: the ship moved toward the click, the piece
-- changed column, the board shifted. A handler that silently does nothing
-- passes a fuzz test easily, which is exactly the failure this is here to
-- catch. Coordinates are terminal cells (1..51, 1..19), the same thing
-- CC:Tweaked hands a program.

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
  input = input, audio = audio, data = data, ui = req("lib.ui"),
  require = req,
}

local function build(id, modeIdx)
  local def = req("games." .. id)
  local mode = def.modes and def.modes[modeIdx or 1] or nil
  -- new() must not block, same guard the per-game test uses
  local saved = MOCK.eventBudget
  MOCK.eventBudget = 40
  local ok, inst = pcall(def.new, api, mode)
  MOCK.eventBudget = saved
  check(ok, id .. ": new() did not block: " .. tostring(inst))
  if not ok then error("construction failed for " .. id, 0) end
  return def, inst
end

local function send(inst, kind, btn, x, y)
  input.onMouse(kind, btn, x, y)
  if inst.onMouse then
    local ok, err = pcall(inst.onMouse, inst, kind, btn, x, y)
    check(ok, "onMouse(" .. kind .. ") did not error: " .. tostring(err))
  end
end

local function run(inst, frames, dt)
  for _ = 1, frames or 1 do
    local ok, err = pcall(inst.update, inst, dt or 0.05)
    check(ok, "update did not error: " .. tostring(err))
  end
end

--------------------------------------------------------- every game responds
-- The declared controls and the implemented handler have to agree: a game
-- that advertises "Mouse" in its help must have an onMouse, and one that has
-- an onMouse should say so, or nobody will ever find it.
for _, id in ipairs({ "snake", "tetris", "breakout", "bombard", "minesweeper",
                      "g2048", "sokoban", "flappy", "pong", "meteors",
                      "lightsout", "simon", "connect4" }) do
  local def, inst = build(id)
  local claims = false
  for _, row in ipairs(def.controls or {}) do
    local label = tostring(row[1]):lower()
    if label:find("mouse") or label:find("click") then claims = true end
  end
  check(inst.onMouse ~= nil, id .. " handles the mouse")
  check(claims, id .. " lists a pointer control in its help")
end

-------------------------------------------------------------------- bombard
do
  local _, inst = build("bombard")
  local t = inst.tanks[1]
  t.angle, t.power = 45, 50

  -- Drag back and to the right of the gun: the barrel should swing the other
  -- way, and the length of the pull should become the power.
  send(inst, "mouse_click", 1, 20, 12)
  send(inst, "mouse_drag", 1, 30, 16)
  check(t.angle ~= 45 or t.power ~= 50, "bombard: dragging moved the aim")
  local pulled = t.power

  -- a longer pull is more power
  send(inst, "mouse_drag", 1, 40, 18)
  check(t.power > pulled, "bombard: a longer pull is more power")
  check(t.power <= 100 and t.angle >= 0 and t.angle <= 180,
    "bombard: aim stays in range (ang " .. math.floor(t.angle) ..
    ", pwr " .. math.floor(t.power) .. ")")

  -- releasing fires
  check(inst.phase == "aim", "bombard: still aiming before release")
  send(inst, "mouse_up", 1, 40, 18)
  check(inst.phase == "flight", "bombard: releasing fires the shot")

  -- and the opponent's turn must not accept our pointer
  run(inst, 400)
  if not inst.finished and inst.turn == 2 and inst.cpu then
    local before = inst.tanks[2].angle
    send(inst, "mouse_drag", 1, 10, 10)
    check(inst.tanks[2].angle == before, "bombard: the pointer cannot aim for the opponent")
  end
end

----------------------------------------------------------------------- pong
do
  local _, inst = build("pong")
  local startY = inst.leftY
  send(inst, "mouse_click", 1, 25, 17)          -- low on the court
  run(inst, 20)
  check(inst.leftY > startY, "pong: the paddle followed the pointer down")
  local low = inst.leftY
  send(inst, "mouse_click", 1, 25, 6)           -- high again
  run(inst, 20)
  check(inst.leftY < low, "pong: the paddle followed the pointer back up")

  -- a key press has to take the paddle back off the mouse
  send(inst, "mouse_click", 1, 25, 17)
  input.onKey(keys.w, false)
  run(inst, 2)
  check(inst.mouseY == nil, "pong: a key press takes the paddle off the mouse")
  input.onKeyUp(keys.w)
end

---------------------------------------------------------------------- snake
do
  local _, inst = build("snake")
  local head = inst.body[inst.head]
  -- click well below the head: the snake should be steering downward
  send(inst, "mouse_click", 1, math.floor((head.x * 3 + 2) / 2), 18)
  local queued = inst.queue[#inst.queue] or inst.lastQueued
  check(queued == "down" or queued == "up",
    "snake: a click queued a vertical turn (got " .. tostring(queued) .. ")")
end

--------------------------------------------------------------------- tetris
do
  local _, inst = build("tetris")
  local before = inst.px
  send(inst, "mouse_click", 1, 18, 8)           -- left side of the well
  run(inst, 12)
  check(inst.px < before, "tetris: the piece slid toward the clicked column")

  -- scrolling rotates
  local rot = inst.rot
  send(inst, "mouse_scroll", 1, 25, 8)
  check(inst.rot ~= rot, "tetris: the wheel rotated the piece")

  -- clicking under the well hard drops
  local drops = inst.pieces or 0
  local py = inst.py
  send(inst, "mouse_click", 1, 25, 19)
  check(inst.py ~= py or (inst.pieces or 0) ~= drops,
    "tetris: clicking below the well dropped the piece")
end

-------------------------------------------------------------------- sokoban
do
  local _, inst = build("sokoban")
  local sx, sy = inst.px, inst.py
  -- walk to a reachable free square that is not next door, so the path
  -- finder rather than the single-step branch is exercised
  local target
  for y = 1, inst.h do
    for x = 1, inst.w do
      local k = inst:key(x, y)
      if not inst.walls[k] and not inst.boxes[k] then
        local d = math.abs(x - sx) + math.abs(y - sy)
        if d > 1 and (not target or d > target[3]) then target = { x, y, d } end
      end
    end
  end
  check(target ~= nil, "sokoban: found a distant free square to walk to")
  send(inst, "mouse_click", 1,
    inst.ox + (target[1] - 1) * inst.cw,
    inst.oy + (target[2] - 1) * inst.ch)
  check(inst.path ~= nil, "sokoban: a click planned a walk")
  run(inst, 200)
  check(inst.px ~= sx or inst.py ~= sy, "sokoban: the walk actually moved")
  check(inst.path == nil, "sokoban: the walk finished rather than looping")

  -- clicking a wall must be ignored, not throw or strand a path
  local wx, wy
  for y = 1, inst.h do
    for x = 1, inst.w do
      if inst.walls[inst:key(x, y)] then wx, wy = x, y end
    end
  end
  if wx then
    send(inst, "mouse_click", 1,
      inst.ox + (wx - 1) * inst.cw, inst.oy + (wy - 1) * inst.ch)
    check(inst.path == nil, "sokoban: clicking a wall plans nothing")
  end
  -- and a click miles off the board is harmless
  send(inst, "mouse_click", 1, 1, 1)
  send(inst, "mouse_click", 1, 51, 19)
  run(inst, 4)
end

----------------------------------------------------------------------- 2048
do
  local _, inst = build("g2048")
  local function snapshot()
    local out = {}
    for i = 1, 16 do out[i] = inst.grid[i] or 0 end
    return table.concat(out, ",")
  end

  local before = snapshot()
  -- a swipe: press, move far enough to count, release
  send(inst, "mouse_click", 1, 25, 10)
  send(inst, "mouse_drag", 1, 25, 17)
  send(inst, "mouse_up", 1, 25, 17)
  run(inst, 20)
  check(snapshot() ~= before, "2048: a swipe moved the board")

  -- a tap with no drag still counts, via the edge rule
  before = snapshot()
  local moved = false
  for _, at in ipairs({ { 4, 10 }, { 47, 10 }, { 25, 3 }, { 25, 17 } }) do
    send(inst, "mouse_click", 1, at[1], at[2])
    send(inst, "mouse_up", 1, at[1], at[2])
    run(inst, 20)
    if snapshot() ~= before then moved = true break end
  end
  check(moved, "2048: a tap toward an edge moved the board")
end

-------------------------------------------------------------------- meteors
do
  input.reset()                 -- no stray held keys from an earlier block
  local _, inst = build("meteors")
  -- Keep the sky empty for the whole run. Clearing it once is not enough:
  -- the wave ends, a fresh one spawns on top of the ship and kills it, and a
  -- dead ship ignores the pointer -- which is correct behaviour, but it
  -- measures the wrong thing here.
  local function fly(frames)
    for _ = 1, frames do
      inst.rocks = {}
      run(inst, 1)
    end
  end
  local s = inst.ship
  s.x, s.y, s.angle = 51, 28, 0          -- pointing right
  -- click straight above: the ship should start turning that way
  send(inst, "mouse_click", 1, 26, 3)
  local before = s.angle
  fly(10)
  check(s.angle ~= before, "meteors: the ship turned toward the pointer")

  -- keep going, then confirm it is actually facing up rather than spinning
  fly(60)
  check(not inst.dead, "meteors: the ship survived an empty sky")
  local fy = math.sin(s.angle)
  check(fy < -0.5, "meteors: the ship settled facing the pointer (sin=" ..
    string.format("%.2f", fy) .. ")")

  -- right click burns the engine
  send(inst, "mouse_click", 2, 26, 3)
  check((inst.thrustBurst or 0) > 0, "meteors: right click lit the engine")
  fly(2)
  check(inst.ship.thrust, "meteors: the burst counts as thrust")
end

------------------------------------------------------------- monitor touch
-- A touch on an advanced monitor arrives as a single monitor_touch with no
-- release. The runtime has to synthesise the release, or a swipe game waits
-- forever. This checks the 2048 handler survives the synthetic pair.
do
  local _, inst = build("g2048")
  send(inst, "mouse_click", 1, 25, 17)
  send(inst, "mouse_up", 1, 25, 17)
  run(inst, 20)
  local sum = 0
  for i = 1, 16 do sum = sum + (inst.grid[i] or 0) end
  check(sum > 0, "2048: a monitor-style touch pair is handled")
end

gfx.shutdown()
finish("mouse")
