-- Validates the whole sound system: note ranges, instruments, the per-tick
-- speaker budget, the volume knobs, and that every effect a game asks for
-- actually exists.
local req = require_gameos
local gfx = req("lib.gfx")
local audio = req("lib.audio")
local data = req("lib.data")

gfx.init()
data.load()
audio.init()

local sfx = req("lib.sfx")
local music = req("lib.music")

--------------------------------------------------------------- definitions
do
  for _, bad in ipairs(music.badTokens) do LOG("  bad music token: " .. bad) end
  eq(#music.badTokens, 0, "every music token parses and is in range")
  for _, bad in ipairs(audio.badNotes) do LOG("  bad note name: " .. bad) end
  eq(#audio.badNotes, 0, "every note name resolves")

  local names = sfx.names()
  LOG("  " .. #names .. " effects, " .. #music.names() .. " songs")
  check(#names >= 70, "a sound for essentially every action")

  local problems = 0
  for _, name in ipairs(names) do
    local def = sfx.get(name)
    if type(def) ~= "table" or #def == 0 then
      problems = problems + 1
      LOG("  " .. name .. " is empty")
    else
      for i = 1, #def do
        local e = def[i]
        if type(e[1]) ~= "number" or e[1] < 0 or e[1] > 2 then
          problems = problems + 1
          LOG("  " .. name .. " event " .. i .. " has a silly delay")
        end
        if not audio.instruments[e[2]] then
          problems = problems + 1
          LOG("  " .. name .. " uses unknown instrument " .. tostring(e[2]))
        end
        if type(e[3]) ~= "number" or e[3] < 0 or e[3] > 24 then
          problems = problems + 1
          LOG("  " .. name .. " event " .. i .. " pitch out of range: " .. tostring(e[3]))
        end
        if type(e[4]) ~= "number" or e[4] <= 0 or e[4] > 1.5 then
          problems = problems + 1
          LOG("  " .. name .. " event " .. i .. " volume out of range: " .. tostring(e[4]))
        end
      end
    end
  end
  eq(problems, 0, "every effect is well formed")
end

------------------------------------------------- every name a game asks for
do
  local missing, checked = 0, 0
  for file in tostring(__diskList()):gmatch("[^\n]+") do
    if file:sub(-4) == ".lua" then
      local src = __diskRead(file)
      -- only literal names: a call like audio.play("inv.march" .. n) names a
      -- family, and those are checked explicitly below
      for name in src:gmatch('audio%.play%("([^"]+)"%s*[,)]') do
        checked = checked + 1
        if not sfx.get(name) then
          missing = missing + 1
          LOG("  " .. file .. " plays missing effect: " .. name)
        end
      end
      for name in src:gmatch('audio%.playMusic%("([^"]+)"') do
        if not music.get(name) then
          missing = missing + 1
          LOG("  " .. file .. " asks for missing song: " .. name)
        end
      end
    end
  end
  -- the families built by concatenation
  for _, family in ipairs({
    { "inv.march", 4 }, { "met.rock", 3 }, { "sim.pad", 4 },
    { "tet.line", 3 },
  }) do
    for i = 1, family[2] do
      if not sfx.get(family[1] .. i) then
        missing = missing + 1
        LOG("  missing family member: " .. family[1] .. i)
      end
    end
  end
  LOG("  " .. checked .. " play() call sites checked")
  eq(missing, 0, "no game asks for a sound that does not exist")
  check(checked >= 60, "sounds are actually used across the console")
end

--------------------------------------------------------- the speaker budget
-- The speaker takes eight notes a tick. Drive every effect and every song and
-- confirm nothing ever asks for more.
do
  local perTick = {}
  local tick = 0
  local realFind = peripheral.find
  local counting = {
    playNote = function(inst, vol, pitch)
      perTick[tick] = (perTick[tick] or 0) + 1
      check(audio.instruments[inst], "instrument is real: " .. tostring(inst))
      check(vol >= 0 and vol <= 3, "volume inside 0..3: " .. tostring(vol))
      check(pitch >= 0 and pitch <= 24 and math.floor(pitch) == pitch,
        "pitch is a whole 0..24: " .. tostring(pitch))
      return true
    end,
  }
  audio.speaker = counting

  local worst = 0
  local function run(seconds, before)
    local steps = math.floor(seconds / 0.05)
    for i = 1, steps do
      tick = tick + 1
      -- the runtime pumps audio at the top of the frame and only then runs
      -- game code, so effects and music share one tick's allowance
      audio.update(tick * 0.05)
      if before then before(i) end
      local n = perTick[tick] or 0
      if n > worst then worst = n end
    end
  end

  -- every effect on its own
  for _, name in ipairs(sfx.names()) do
    audio.play(name)
    run(1.2)
  end
  LOG("  worst tick with effects alone: " .. worst .. " notes")
  check(worst <= 8, "no effect exceeds the speaker's eight notes per tick")

  -- every song, played right through
  for _, id in ipairs(music.names()) do
    audio.playMusic(id)
    local before = worst
    run(music.length(id) + 0.5)
    LOG(string.format("  %-11s %5.1fs, worst tick %d notes",
      id, music.length(id), worst))
    worst = before > worst and before or worst
  end
  check(worst <= 8, "no song exceeds the speaker budget")

  -- the nastiest case: music running while effects fire every tick
  audio.playMusic("cascade")
  local spam = 0
  run(6, function()
    spam = spam + 1
    if spam % 2 == 0 then audio.play("tet.harddrop") end
    if spam % 3 == 0 then audio.play("tet.tetris") end
    if spam % 5 == 0 then audio.play("met.die") end
  end)
  LOG("  worst tick, music plus effect spam: " .. worst .. " notes")
  check(worst <= 8, "effects and music together stay inside the budget")

  audio.stopAll()
  audio.speaker = nil
  peripheral.find = realFind
end

--------------------------------------------------------------- volume knobs
do
  local played = 0
  audio.speaker = { playNote = function() played = played + 1 return true end }

  audio.volumes.master = 0
  played = 0
  audio.play("ui.select")
  audio.update(100)
  eq(played, 0, "master at zero is silent")

  audio.volumes.master = 0.7
  audio.volumes.sfx = 0
  played = 0
  audio.play("ui.select")
  audio.update(101)
  eq(played, 0, "effects volume at zero silences effects")

  audio.volumes.sfx = 1
  played = 0
  audio.play("ui.select")
  audio.update(102)
  check(played > 0, "effects play again when turned up")

  -- music can be silenced without touching effects
  audio.volumes.music = 0
  audio.playMusic("standby")
  played = 0
  for i = 1, 40 do audio.update(102 + i * 0.05) end
  eq(played, 0, "music volume at zero silences the soundtrack")

  audio.volumes.music = 0.6
  played = 0
  for i = 1, 40 do audio.update(110 + i * 0.05) end
  check(played > 0, "music plays again when turned up")

  -- levels land inside the speaker's range at every knob setting
  local seen = {}
  audio.speaker = { playNote = function(_, vol) seen[#seen + 1] = vol return true end }
  for _, m in ipairs({ 0.1, 0.5, 1.0 }) do
    audio.volumes.master = m
    audio.play("met.die")
    for i = 1, 20 do audio.update(200 + m * 10 + i * 0.05) end
  end
  local outOfRange = 0
  for _, v in ipairs(seen) do
    if v < 0 or v > 3 then outOfRange = outOfRange + 1 end
  end
  eq(outOfRange, 0, "every emitted level sits inside 0..3")
  check(#seen > 0, "the loud test actually produced notes")

  audio.stopAll()
  audio.speaker = nil
  audio.volumes.master, audio.volumes.music, audio.volumes.sfx = 0.7, 0.6, 1.0
end

------------------------------------------------------------- music sequencing
do
  local notes = 0
  audio.speaker = { playNote = function() notes = notes + 1 return true end }
  audio.playMusic("standby")
  eq(audio.musicName(), "standby", "the playing song is reported")
  audio.playMusic("standby")
  eq(audio.musicName(), "standby", "restarting the same song is a no-op")
  audio.playMusic("cascade")
  eq(audio.musicName(), "cascade", "switching songs works")

  -- a full loop should keep producing notes, i.e. the order list wraps
  notes = 0
  local span = music.length("cascade")
  for i = 1, math.floor(span * 2 / 0.05) do audio.update(300 + i * 0.05) end
  check(notes > 100, "a looping song keeps playing (" .. notes .. " notes over two passes)")

  audio.stopMusic()
  notes = 0
  for i = 1, 40 do audio.update(400 + i * 0.05) end
  eq(notes, 0, "stopping the music actually stops it")

  audio.speaker = nil
end

--------------------------------------------------------------- no speaker
do
  audio.speaker = nil
  audio.play("met.die")
  audio.playMusic("cascade")
  for i = 1, 40 do audio.update(500 + i * 0.05) end
  check(true, "everything is a silent no-op with no speaker attached")
end

gfx.shutdown()
finish("sound")
