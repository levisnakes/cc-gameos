--[[ audio -- non-blocking sound effects and background music.

  Nothing here ever sleeps: play() queues notes with timestamps and update()
  fires the ones that are due, so a 6-note explosion costs no frame time.
  With no speaker attached every call is a silent no-op.
]]

local audio = {}

audio.speaker = nil
audio.sfxOn = true
audio.musicOn = false
audio.volume = 1.0

local pending = {}
local music = nil
local now = 0

function audio.init()
  local ok, found = pcall(peripheral.find, "speaker")
  audio.speaker = ok and found or nil
  return audio.speaker ~= nil
end

------------------------------------------------------------------ note names
local N = {}
do
  local names = { "FS", "G", "GS", "A", "AS", "B", "C", "CS", "D", "DS", "E", "F" }
  local octave = 3
  local p = 0
  for i = 1, 25 do
    local idx = ((i - 1) % 12) + 1
    if names[idx] == "C" and i > 1 then octave = octave + 1 end
    N[names[idx] .. octave] = p
    p = p + 1
  end
end
audio.notes = N

--------------------------------------------------------------------- effects
-- Each entry is a list of { delay, instrument, pitch, volume }.
audio.sfx = {
  move        = { { 0.00, "hat", 12, 0.25 } },
  select      = { { 0.00, "pling", 14, 0.45 }, { 0.05, "pling", 18, 0.45 } },
  back        = { { 0.00, "pling", 13, 0.40 }, { 0.05, "pling", 8, 0.35 } },
  deny        = { { 0.00, "bass", 4, 0.5 }, { 0.08, "bass", 2, 0.5 } },
  start       = { { 0.00, "bell", 12, 0.5 }, { 0.07, "bell", 16, 0.5 }, { 0.14, "bell", 19, 0.6 } },
  eat         = { { 0.00, "bell", 17, 0.5 }, { 0.05, "bell", 21, 0.5 } },
  coin        = { { 0.00, "chime", 19, 0.5 }, { 0.06, "chime", 23, 0.5 } },
  blip        = { { 0.00, "bit", 16, 0.35 } },
  laser       = { { 0.00, "bit", 21, 0.35 }, { 0.04, "bit", 15, 0.3 }, { 0.08, "bit", 10, 0.25 } },
  hit         = { { 0.00, "basedrum", 6, 0.7 } },
  bounce      = { { 0.00, "bit", 14, 0.4 } },
  thud        = { { 0.00, "bass", 6, 0.6 } },
  lock        = { { 0.00, "bass", 9, 0.45 } },
  explode     = { { 0.00, "basedrum", 2, 1.0 }, { 0.06, "snare", 7, 0.8 }, { 0.13, "snare", 4, 0.6 }, { 0.22, "snare", 1, 0.4 } },
  clear       = { { 0.00, "xylophone", 12, 0.5 }, { 0.05, "xylophone", 16, 0.5 }, { 0.10, "xylophone", 19, 0.55 }, { 0.15, "xylophone", 24, 0.6 } },
  levelup     = { { 0.00, "bell", 12, 0.6 }, { 0.09, "bell", 16, 0.6 }, { 0.18, "bell", 19, 0.6 }, { 0.27, "bell", 24, 0.7 } },
  powerup     = { { 0.00, "iron_xylophone", 12, 0.5 }, { 0.05, "iron_xylophone", 17, 0.5 }, { 0.10, "iron_xylophone", 22, 0.55 } },
  gameover    = { { 0.00, "harp", 14, 0.6 }, { 0.16, "harp", 11, 0.6 }, { 0.32, "harp", 7, 0.6 }, { 0.48, "bass", 3, 0.7 } },
  win         = { { 0.00, "bell", 12, 0.6 }, { 0.10, "bell", 16, 0.6 }, { 0.20, "bell", 19, 0.6 }, { 0.30, "bell", 24, 0.7 }, { 0.45, "bell", 19, 0.5 }, { 0.55, "bell", 24, 0.8 } },
  boot        = { { 0.00, "bit", 7, 0.5 }, { 0.09, "bit", 12, 0.5 }, { 0.18, "bit", 16, 0.5 }, { 0.27, "bit", 19, 0.6 }, { 0.40, "bit", 24, 0.7 } },
  flap        = { { 0.00, "hat", 18, 0.3 } },
  step        = { { 0.00, "hat", 8, 0.25 } },
  push        = { { 0.00, "bass", 10, 0.35 } },
  reveal      = { { 0.00, "hat", 15, 0.2 } },
  flag        = { { 0.00, "cow_bell", 14, 0.35 } },
  merge       = { { 0.00, "xylophone", 14, 0.4 }, { 0.05, "xylophone", 19, 0.4 } },
  slide       = { { 0.00, "hat", 10, 0.22 } },
  undo        = { { 0.00, "didgeridoo", 8, 0.35 } },
}

----------------------------------------------------------------------- music
audio.badNotes = {}
local function seq(str)
  local out = {}
  for tok in str:gmatch("%S+") do
    if tok == "." then
      out[#out + 1] = false
    else
      local p = N[tok]
      if not p then audio.badNotes[#audio.badNotes + 1] = tok end
      out[#out + 1] = p or false
    end
  end
  return out
end

audio.tracks = {
  menu = {
    tempo = 0.155,
    lead = seq([[A3 C4 E4 A4 E4 C4 A3 .
                 F4 A4 C5 A4 F4 C4 A3 .
                 C4 E4 G4 C5 G4 E4 C4 .
                 G3 B3 D4 G4 D4 B3 G3 .]]),
    bass = seq([[A3 . . . E4 . . .
                 F4 . . . C4 . . .
                 C4 . . . G4 . . .
                 G3 . . . D4 . . .]]),
    leadInst = "pling",
    bassInst = "bass",
  },
}

------------------------------------------------------------------------- api
local function emit(inst, pitch, vol)
  local sp = audio.speaker
  if not sp then return end
  local v = vol * audio.volume
  if v <= 0 then return end
  if v > 3 then v = 3 end
  local p = math.floor(pitch + 0.5)
  if p < 0 then p = 0 elseif p > 24 then p = 24 end
  pcall(sp.playNote, inst, v, p)
end

--- Queue a named effect. `shift` transposes it in semitones.
function audio.play(name, shift)
  if not audio.sfxOn or not audio.speaker then return end
  local def = audio.sfx[name]
  if not def then return end
  shift = shift or 0
  if #pending > 64 then return end
  for i = 1, #def do
    local n = def[i]
    if n[1] <= 0 then
      emit(n[2], n[3] + shift, n[4])
    else
      pending[#pending + 1] = { t = now + n[1], inst = n[2], pitch = n[3] + shift, vol = n[4] }
    end
  end
end

--- Play a single note immediately.
function audio.note(inst, pitch, vol)
  if not audio.sfxOn then return end
  emit(inst, pitch, vol or 0.5)
end

function audio.playMusic(name)
  if not audio.musicOn or not audio.speaker then music = nil return end
  local track = audio.tracks[name]
  if not track then music = nil return end
  music = { track = track, step = 0, nextT = now }
end

function audio.stopMusic()
  music = nil
end

function audio.stopAll()
  for i = #pending, 1, -1 do pending[i] = nil end
  music = nil
end

--- Called once per frame with the current clock reading.
function audio.update(clock)
  now = clock
  if not audio.speaker then
    if #pending > 0 then for i = #pending, 1, -1 do pending[i] = nil end end
    return
  end
  local i = 1
  while i <= #pending do
    local n = pending[i]
    if n.t <= now then
      emit(n.inst, n.pitch, n.vol)
      table.remove(pending, i)
    else
      i = i + 1
    end
  end
  if music and audio.musicOn then
    local track = music.track
    local guard = 0
    while now >= music.nextT and guard < 4 do
      guard = guard + 1
      music.step = music.step + 1
      if music.step > #track.lead then music.step = 1 end
      local l = track.lead[music.step]
      local b = track.bass[music.step]
      if l then emit(track.leadInst, l, 0.30) end
      if b then emit(track.bassInst, b, 0.35) end
      music.nextT = music.nextT + track.tempo
    end
    if music.nextT < now - 1 then music.nextT = now + track.tempo end
  end
end

return audio
