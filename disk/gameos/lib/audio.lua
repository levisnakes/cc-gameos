--[[ audio -- the console's sound engine.

  A ComputerCraft speaker can play at most eight notes per tick, so this is
  built as a budgeted mixer rather than a pile of playNote calls:

    * effects are scheduled ahead of time and cost no frame time when they
      fire, so a nine-note explosion is as cheap as a click;
    * music runs a small tracker (patterns, an order list, real tempo in
      seconds) and is the first thing dropped when the tick budget is tight,
      so gameplay feedback is never masked by the soundtrack;
    * three independent volumes -- master, music, effects -- scale into the
      speaker's 0..3 range.

  With no speaker attached every call is a silent no-op.
]]

local req = ...

local audio = {}

local floor = math.floor
local min, max = math.min, math.max

-- a speaker accepts eight notes per tick; leave one spare for a late effect
local NOTES_PER_TICK = 8
local RESERVED_FOR_SFX = 3

audio.speaker = nil
audio.volumes = { master = 0.7, music = 0.6, sfx = 1.0 }

local pending = {}
local music = nil
local now = 0
local budget = NOTES_PER_TICK

--------------------------------------------------------------------- notes
-- CC pitch 0..24 spans F#3 to F#5. Instruments are voiced at different
-- octaves, so "bass" at pitch 0 sounds far below "bell" at pitch 0.
local NAMES = { "FS", "G", "GS", "A", "AS", "B", "C", "CS", "D", "DS", "E", "F" }
local NOTE = {}
do
  local octave = 3
  for i = 0, 24 do
    local name = NAMES[(i % 12) + 1]
    if name == "C" and i > 0 then octave = octave + 1 end
    NOTE[name .. octave] = i
  end
end
audio.NOTE = NOTE
audio.badNotes = {}

--- Accept a pitch as a number or a note name.
function audio.pitch(value)
  if type(value) == "number" then return value end
  local p = NOTE[value]
  if not p then
    audio.badNotes[#audio.badNotes + 1] = tostring(value)
    return 12
  end
  return p
end

local VALID_INSTRUMENTS = {
  harp = true, basedrum = true, snare = true, hat = true, bass = true,
  flute = true, bell = true, guitar = true, chime = true, xylophone = true,
  iron_xylophone = true, cow_bell = true, didgeridoo = true, bit = true,
  banjo = true, pling = true,
}
audio.instruments = VALID_INSTRUMENTS

------------------------------------------------------------------- lifecycle
function audio.init()
  local ok, found = pcall(peripheral.find, "speaker")
  audio.speaker = (ok and found) or nil
  audio.sfx = req("lib.sfx")
  audio.songs = req("lib.music")
  return audio.speaker ~= nil
end

function audio.setVolume(kind, value)
  audio.volumes[kind] = max(0, min(1, value))
end

--- True when anything would actually be audible.
function audio.audible(kind)
  if not audio.speaker then return false end
  return audio.volumes.master > 0 and audio.volumes[kind] > 0
end

---------------------------------------------------------------------- mixer
--- Push one note at the speaker, respecting the per-tick budget.
local function emit(instrument, pitch, volume, kind)
  local sp = audio.speaker
  if not sp then return false end
  if budget <= 0 then return false end
  -- music yields the last few notes of the tick to effects
  if kind == "music" and budget <= RESERVED_FOR_SFX then return false end

  local level = volume * audio.volumes[kind] * audio.volumes.master * 3
  if level <= 0.02 then return false end
  if level > 3 then level = 3 end

  local p = floor(pitch + 0.5)
  if p < 0 then p = 0 elseif p > 24 then p = 24 end

  budget = budget - 1
  pcall(sp.playNote, instrument, level, p)
  return true
end
audio.emit = emit

--------------------------------------------------------------------- effects
--- Play a named effect. `opts` may be a semitone shift, or a table with
--- `shift` and `vol` (a multiplier on the effect's own levels).
function audio.play(name, opts)
  if not audio.audible("sfx") then return end
  local def = audio.sfx and audio.sfx.get(name)
  if not def then return end

  local shift, scale = 0, 1
  if type(opts) == "number" then
    shift = opts
  elseif type(opts) == "table" then
    shift = opts.shift or 0
    scale = opts.vol or 1
  end

  if #pending > 96 then return end
  for i = 1, #def do
    local event = def[i]
    if event[1] <= 0 then
      emit(event[2], event[3] + shift, event[4] * scale, "sfx")
    else
      pending[#pending + 1] = {
        t = now + event[1],
        inst = event[2],
        pitch = event[3] + shift,
        vol = event[4] * scale,
      }
    end
  end
end

--- One note, right now. Used where a game owns the pitch (Simon's panels).
function audio.note(instrument, pitch, volume)
  if not audio.audible("sfx") then return end
  emit(instrument, audio.pitch(pitch), volume or 0.5, "sfx")
end

function audio.stopEffects()
  for i = #pending, 1, -1 do pending[i] = nil end
end

----------------------------------------------------------------------- music
--- Start a song by name. Restarting the song that is already playing is a
--- no-op, so screens can call this freely.
function audio.playMusic(name)
  if not name then return audio.stopMusic() end
  if music and music.name == name then return end
  local song = audio.songs and audio.songs.get(name)
  if not song then
    music = nil
    return
  end
  music = {
    name = name,
    song = song,
    orderIndex = 1,
    row = 0,
    acc = 0,
    rowTime = song.tempo * 0.05,
  }
end

function audio.stopMusic()
  music = nil
end

function audio.musicName()
  return music and music.name or nil
end

function audio.stopAll()
  audio.stopEffects()
  audio.stopMusic()
end

--- Play one row of the current pattern.
local function playRow()
  local song = music.song
  local patternName = song.order[music.orderIndex]
  local pattern = song.patterns[patternName]
  if not pattern then return end

  for i = 1, #pattern do
    local track = pattern[i]
    local note = track.rows[music.row]
    if note then
      emit(track.inst, note.pitch, note.vol * track.vol, "music")
    end
  end

  music.row = music.row + 1
  if music.row > song.rows then
    music.row = 1
    music.orderIndex = music.orderIndex + 1
    if music.orderIndex > #song.order then
      music.orderIndex = song.loop or 1
    end
  end
end

--------------------------------------------------------------------- update
--- Called once per frame with the current clock reading.
function audio.update(clock)
  local dt = clock - now
  if dt < 0 or dt > 1 then dt = 0.05 end
  now = clock
  budget = NOTES_PER_TICK

  if not audio.speaker then
    if #pending > 0 then audio.stopEffects() end
    return
  end

  -- effects first: they are feedback, music is decoration
  local i = 1
  while i <= #pending do
    local event = pending[i]
    if event.t <= now then
      emit(event.inst, event.pitch, event.vol, "sfx")
      table.remove(pending, i)
    else
      i = i + 1
    end
  end

  if music and audio.audible("music") then
    if music.row == 0 then music.row = 1 end
    music.acc = music.acc + dt
    local guard = 0
    while music.acc >= music.rowTime and guard < 4 do
      music.acc = music.acc - music.rowTime
      guard = guard + 1
      playRow()
    end
    if music.acc > music.rowTime * 4 then music.acc = 0 end
  end
end

return audio
