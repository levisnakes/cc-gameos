-- Attract mode: the console playing itself while nobody is at it.
--
-- Two things have to hold. Every demo bot must survive a long run without
-- throwing, because a crash here happens with nobody watching and would take
-- the launcher down. And every bot must actually play -- a bot that quietly
-- does nothing still passes "did not crash", and would leave the console
-- showing a motionless game for twenty seconds.

local req = require_gameos
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local font = req("lib.font")
local input = req("lib.input")
local audio = req("lib.audio")
local data = req("lib.data")
local ui = req("lib.ui")

check(gfx.init(), "gfx.init")
data.load()
audio.init()

local api = {
  version = "test", gfx = gfx, canvas = Canvas, font = font,
  input = input, audio = audio, data = data, ui = ui, require = req,
}

------------------------------------------------------------------ the bots
local withDemos = {}
for _, file in ipairs(fs.list("/gameos/games")) do
  if file:sub(-4) == ".lua" then
    local id = file:sub(1, #file - 4)
    local def = req("games." .. id)
    def.id = def.id or id
    if type(def.demo) == "function" then withDemos[#withDemos + 1] = def end
  end
end

check(#withDemos >= 3, "several games can demo themselves (" .. #withDemos .. ")")

--- A rough measure of "is anything happening": enough of the visible state
--- that a frozen game and a playing one cannot look the same.
local function pulse(inst)
  local n = 0
  for _, k in ipairs({ "score", "apples", "level", "lives", "round", "y",
                       "scroll", "paddleX", "turn" }) do
    if type(inst[k]) == "number" then n = n + inst[k] end
  end
  if type(inst.body) == "table" then n = n + #inst.body end
  if type(inst.balls) == "table" then n = n + #inst.balls end
  if type(inst.pipes) == "table" then n = n + #inst.pipes end
  if type(inst.shots) == "table" then
    n = n + (inst.shots[1] or 0) + (inst.shots[2] or 0)
  end
  return n
end

for _, def in ipairs(withDemos) do
  local mode = def.modes and def.modes[1] or nil
  local built, inst = pcall(def.new, api, mode)
  check(built, def.id .. ": demo instance builds: " .. tostring(inst))

  if built then
    local start = pulse(inst)
    local moved = false
    local frames = 0
    for f = 1, 900 do
      frames = f
      local ok, err = pcall(def.demo, inst, f)
      check(ok, def.id .. ": demo bot frame " .. f .. ": " .. tostring(err))
      if not ok then break end
      ok, err = pcall(inst.update, inst, 0.05)
      check(ok, def.id .. ": update under the demo bot: " .. tostring(err))
      if not ok then break end
      -- draw too: the launcher draws every demo frame, so a drawing bug
      -- belongs to this test as much as a rules bug does
      gfx.beginFrame()
      ok, err = pcall(inst.draw, inst)
      gfx.endFrame()
      check(ok, def.id .. ": draw under the demo bot: " .. tostring(err))
      if not ok then break end

      if pulse(inst) ~= start then moved = true end
      if inst.finished then break end
    end
    check(moved, def.id .. ": the demo bot actually plays (" .. frames .. " frames)")
  end
end

------------------------------------------------------- how well they play
-- Not a pass/fail bar, just a note in the log: a demo that dies in two
-- seconds every time is a bad advert for the game.
for _, def in ipairs(withDemos) do
  local total, runs = 0, 3
  for _ = 1, runs do
    local inst = def.new(api, def.modes and def.modes[1] or nil)
    local f = 0
    for i = 1, 900 do
      f = i
      pcall(def.demo, inst, i)
      pcall(inst.update, inst, 0.05)
      if inst.finished then break end
    end
    total = total + f
  end
  LOG(string.format("  %-9s demo lasts %.0f frames (%.0fs) on average",
    def.id, total / runs, total / runs * 0.05))
end

------------------------------------------------------------- in the launcher
-- Drive the real launcher, let it go idle, and confirm it starts playing
-- itself and stops the moment a key is pressed.
do
  local shell = req("os.shell")
  local games = {}
  for _, def in ipairs(withDemos) do games[#games + 1] = def end
  table.sort(games, function(a, b) return (a.order or 50) < (b.order or 50) end)

  local shellApi = {}
  for k, v in pairs(api) do shellApi[k] = v end
  shellApi.games = games
  shellApi.broken = {}
  shellApi.runtime = req("lib.runtime")

  local function screenHas(text)
    local snap = MOCK.snapshot()
    for y = 1, snap.h do
      local row = {}
      for x = 1, snap.w do row[x] = string.char(snap.rows[y].ch[x]) end
      if table.concat(row):find(text, 1, true) then return true end
    end
    return false
  end

  local sawDemo, sawAfterKey = false, nil
  local frames = 0
  AUTO = function()
    frames = frames + 1
    -- IDLE_LIMIT is 45s at 0.08s a frame, so the demo starts around frame 570
    if frames > 600 and not sawDemo then
      if screenHas("DEMO") then
        sawDemo = true
        SHOT("attract")
        MOCK.push("key", keys.down, false)     -- a player arrives
      end
    end
    if sawDemo and sawAfterKey == nil and frames > 640 then
      sawAfterKey = screenHas("DEMO")
      MOCK.push("terminate")
    end
    if frames > 900 then
      MOCK.push("terminate")
      error("HARNESS_DONE", 0)
    end
  end
  local ok, err = pcall(shell.run, shellApi)
  AUTO = nil
  ui.terminated = false

  check(ok or tostring(err):find("HARNESS_DONE"), "the launcher survived: " .. tostring(err))
  check(sawDemo, "the launcher starts playing itself when left alone")
  check(sawAfterKey == false, "and stops the moment a key is pressed")
end

gfx.shutdown()
finish("attract")
