-- The in-game guide: the pause overlay, and the trophy toast.
--
-- Both are things a player meets constantly and neither had any coverage. The
-- overlay is driven here through the real runtime, by pressing P mid-session
-- exactly as a player would, because the interesting failures are in the
-- wiring -- a menu that does not close, a volume change that does not stick,
-- a nested screen that strands the loop -- rather than in the drawing.

local req = require_gameos
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local font = req("lib.font")
local input = req("lib.input")
local audio = req("lib.audio")
local data = req("lib.data")
local ui = req("lib.ui")
local runtime = req("lib.runtime")

check(gfx.init(), "gfx.init")
data.load()
audio.init()

local api = {
  version = "test", gfx = gfx, canvas = Canvas, font = font,
  input = input, audio = audio, data = data, ui = ui, runtime = runtime,
  require = req, games = {}, broken = {},
}

local def = req("games.snake")
def.id = def.id or "snake"

--- Play a session, running `script(frame)` each frame to drive it.
local function session(script, limit)
  local frames = 0
  AUTO = function()
    frames = frames + 1
    script(frames)
    if frames > (limit or 400) then error("HARNESS_DONE", 0) end
  end
  data.progress("snake").seenControls = true
  local ok, err = pcall(runtime.play, def, api)
  AUTO = nil
  ui.terminated = false
  return ok, err, frames
end

------------------------------------------------------------------ the overlay
-- Opening the guide and resuming must give the game back, not quit it.
do
  data.set("volMaster", 7)
  local resumed = false
  session(function(f)
    if f == 3 then MOCK.push("key", keys.enter, false) end        -- pick a mode
    if f == 8 then MOCK.push("key", keys.p, false) end            -- open guide
    if f == 12 then SHOT("pause-guide") end
    if f == 14 then MOCK.push("key", keys.p, false) end           -- and close it
    if f == 20 then resumed = true MOCK.push("terminate") end
  end, 60)
  check(resumed, "the guide opened and the session carried on")
  check(data.get("volMaster") == 7, "resuming changed no settings")
end

-- The volume knobs are the whole point of a guide: turn one down from inside
-- a game and it must stick.
do
  data.set("volMaster", 7)
  audio.volumes.master = 0.7
  session(function(f)
    if f == 3 then MOCK.push("key", keys.enter, false) end
    if f == 8 then MOCK.push("key", keys.p, false) end
    -- down four rows to Master, then left three times
    if f == 10 then MOCK.push("key", keys.down, false) end
    if f == 11 then MOCK.push("key", keys.down, false) end
    if f == 12 then MOCK.push("key", keys.down, false) end
    if f == 13 then MOCK.push("key", keys.down, false) end
    if f == 14 then MOCK.push("key", keys.left, false) end
    if f == 15 then MOCK.push("key", keys.left, false) end
    if f == 16 then MOCK.push("key", keys.left, false) end
    if f == 18 then MOCK.push("key", keys.p, false) end
    if f == 24 then MOCK.push("terminate") end
  end, 60)
  check(data.get("volMaster") == 4,
    "the master knob moved 7 -> 4 (got " .. data.get("volMaster") .. ")")
  check(math.abs(audio.volumes.master - 0.4) < 0.001,
    "and the mixer followed it immediately")

  -- and it must be on disk, not just in memory
  data.load()
  check(data.get("volMaster") == 4, "the change was saved")
end

-- Quitting from the guide has to actually leave. The rows are Resume,
-- Restart, Controls, Trophies, the three knobs, then Quit, so seven presses
-- of Down land on it exactly -- an eighth would wrap back to the top.
do
  local _, _, frames = session(function(f)
    if f == 3 then MOCK.push("key", keys.enter, false) end
    if f == 8 then MOCK.push("key", keys.p, false) end
    for i = 1, 7 do
      if f == 9 + i then MOCK.push("key", keys.down, false) end
    end
    if f == 20 then MOCK.push("key", keys.enter, false) end
    if f == 200 then MOCK.push("terminate") end       -- only if quit failed
  end, 260)
  -- A session that quit returns long before the safety terminate at 200.
  check(frames < 150, "quitting from the guide ended the session (" ..
    frames .. " frames)")
end

-- Right-click anywhere outside is "back", the same as everywhere else.
do
  data.set("volMaster", 6)
  session(function(f)
    if f == 3 then MOCK.push("key", keys.enter, false) end
    if f == 8 then MOCK.push("key", keys.p, false) end
    if f == 12 then MOCK.push("mouse_click", 2, 25, 10) end
    if f == 20 then MOCK.push("terminate") end
  end, 60)
  check(data.get("volMaster") == 6, "a right-click closed the guide harmlessly")
end

---------------------------------------------------------------- trophy toast
--- Read a row of the terminal back as a string, so the test can look for the
--- caption the toast paints rather than trusting that it was drawn.
local function screenRow(snap, y)
  local out = {}
  for x = 1, snap.w do out[x] = string.char(snap.rows[y].ch[x]) end
  return table.concat(out)
end

-- A trophy has to be announced while you are still playing, not saved up for
-- the card at the end. A test trophy that is always earned is enough: it must
-- be recorded, and its caption must appear on screen, both while the session
-- is still running.
do
  local fake = {
    id = "toast_test", name = "Test Trophy", desc = "Awarded at once",
    test = function() return true end,
  }
  local saved = def.trophies
  def.trophies = { fake }
  data.state.trophies[fake.id] = nil

  local heldDuringPlay = false
  local sawCaption = false

  session(function(f)
    if f == 3 then MOCK.push("key", keys.enter, false) end       -- pick a mode
    if f > 20 then
      if data.hasTrophy(fake.id) then heldDuringPlay = true end
      local snap = MOCK.snapshot()
      for y = 2, 6 do
        if screenRow(snap, y):find("TROPHY") then sawCaption = true end
      end
    end
    if f == 70 then MOCK.push("terminate") end
  end, 100)

  check(heldDuringPlay, "a trophy is recorded during the run, not after it")
  check(sawCaption, "and the toast is drawn over the game")

  def.trophies = saved
  data.state.trophies[fake.id] = nil
end

gfx.shutdown()
finish("pause")
